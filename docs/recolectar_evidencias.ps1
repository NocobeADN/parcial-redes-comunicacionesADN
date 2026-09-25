# =====================================================================
#  Recolecta las evidencias de red citadas en INFORME.md (docs/evidencias/).
#  Uso (con el stack arriba):   powershell -File docs/recolectar_evidencias.ps1
#  En Linux/macOS los mismos comandos docker funcionan desde bash.
# =====================================================================
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$out = Join-Path $PSScriptRoot "evidencias"
New-Item -ItemType Directory -Force $out | Out-Null
$proj = (docker compose config --format json | ConvertFrom-Json).name

# Ejecuta un script sh multilínea sin canalizarlo por stdin (PowerShell 5.1 antepone un BOM):
# se pasa codificado en base64 y se decodifica dentro del contenedor.
function ComoArgSh([string]$script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script.Replace("`r", "")))
    return "echo $b64 | base64 -d | sh"
}

function Guardar($nombre, [scriptblock]$bloque) {
    # stderr de los comandos nativos se guarda como texto plano (sin el envoltorio de error de PowerShell)
    $texto = & $bloque 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
    } | Out-String
    [IO.File]::WriteAllText((Join-Path $out $nombre), $texto, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> $nombre"
}

Write-Host "Recolectando evidencias en $out"

Guardar "01_estado_servicios.txt" {
    docker compose ps --format "table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
}

Guardar "02_redes_ip_mac.txt" {
    foreach ($n in "frontend_net", "backend_net") {
        $r = (docker network inspect "${proj}_$n" | ConvertFrom-Json)[0]
        "RED $($r.Name)  driver=$($r.Driver)  internal=$($r.Internal)  subnet=$($r.IPAM.Config[0].Subnet)  gateway=$($r.IPAM.Config[0].Gateway)  bridge=$($r.Options.'com.docker.network.bridge.name')"
        foreach ($c in $r.Containers.PSObject.Properties.Value) {
            "   {0,-42} {1,-16} {2}" -f $c.Name, $c.IPv4Address, $c.MacAddress
        }
        ""
    }
}

Guardar "03_dns_embebido.txt" {
    "### /etc/resolv.conf dentro de joomla"; docker compose exec -T joomla cat /etc/resolv.conf
    "### joomla (frontend+backend) resuelve:"; docker compose exec -T joomla getent hosts database nginx grafana jupyter
    "### nginx (solo frontend_net) intenta resolver 'database':"; docker compose exec -T nginx nslookup database 127.0.0.11
    "### nginx resuelve 'joomla':"; docker compose exec -T nginx nslookup joomla 127.0.0.11
    "### database (solo backend_net) intenta resolver 'nginx':"; docker compose exec -T database nslookup nginx 127.0.0.11
}

Guardar "04_aislamiento_backend.txt" {
    "### Tabla de rutas de database (sin ruta por defecto):"; docker compose exec -T database ip route
    "### database -> Internet (8.8.8.8):"; docker compose exec -T database ping -c1 -W2 8.8.8.8
    "### database -> DNS externo:"; docker compose exec -T database nslookup example.com
    "### Tabla de rutas de joomla (ruta por defecto por frontend_net):"; docker compose exec -T joomla sh -c "cat /proc/net/route"
    "### nginx -> database:5432 (no comparten red):"; docker compose exec -T nginx sh -c "nc -zv -w2 database 5432 2>&1 || nc -zv -w2 10.201.20.2 5432 2>&1 || echo 'sin conectividad'"
}

$hostScript = @'
echo "### Bridges Linux creados por Docker"
ip -br link show type bridge | grep parcial
echo "### Interfaces veth esclavas de cada bridge (peer_ifindex = eth dentro del contenedor)"
for b in br-parcial-fe br-parcial-be; do
  echo "$b:"
  for p in $(ls /sys/class/net/$b/brif); do
    echo "   $p  ifindex=$(cat /sys/class/net/$p/ifindex)  peer_ifindex=$(cat /sys/class/net/$p/iflink)  mac=$(cat /sys/class/net/$p/address)"
  done
done
echo "### IP de los bridges (gateway de cada red)"
ip -br addr show br-parcial-fe; ip -br addr show br-parcial-be
echo "### Reenvío IP del kernel (net.ipv4.ip_forward)"
cat /proc/sys/net/ipv4/ip_forward
echo "### Tabla FDB (MAC -> puerto veth) aprendida por br-parcial-be"
bridge fdb show br br-parcial-be | grep -v permanent
echo "### Reglas NAT (tabla nat)"
iptables-save -t nat 2>/dev/null | grep -E '10\.201|DOCKER'
echo "### Reglas de filtrado/aislamiento relacionadas"
iptables-save -t filter 2>/dev/null | grep -E 'br-parcial|10\.201'
'@
Guardar "05_host_bridges_veth_nat.txt" {
    docker run --rm --privileged --pid=host alpine:3.22 nsenter -t 1 -m -u -n -i sh -c (ComoArgSh $hostScript)
}

Guardar "06_interfaces_contenedor_joomla.txt" {
    "### Interfaces de joomla (eth0/eth1 son extremos de pares veth; @ifNN = ifindex del peer en el host)"
    docker compose exec -T joomla sh -c (ComoArgSh 'for i in /sys/class/net/*; do n=$(basename $i); echo "$n ifindex=$(cat $i/ifindex) iflink=$(cat $i/iflink) mac=$(cat $i/address)"; done')
    "### Caché ARP de joomla"; docker compose exec -T joomla cat /proc/net/arp
}

Guardar "07_captura_arp_tcp_backend.txt" {
    docker rm -f captura-parcial 2>$null | Out-Null
    docker run -d --name captura-parcial --net=host --privileged alpine:3.22 sh -c "apk add -q tcpdump >/dev/null && timeout 20 tcpdump -i br-parcial-be -nn -e -l 'arp or (tcp port 5432 and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0))' 2>/dev/null" | Out-Null
    Start-Sleep 8
    "### Cliente efímero en backend_net (caché ARP vacía) conectando a database:5432"
    $sqlCliente = "psql -h database -U analista -d joomla -tAc `"select 'cliente ' || inet_client_addr() || ':' || inet_client_port() || ' -> servidor ' || inet_server_addr() || ':' || inet_server_port()`""
    docker run --rm --network "${proj}_backend_net" -e PGPASSWORD=Analista_Parcial2026 postgres:16-alpine sh -c (ComoArgSh $sqlCliente)
    Start-Sleep 14
    "### tcpdump -i br-parcial-be (ARP + SYN/FIN de TCP 5432)"
    docker logs captura-parcial
    docker rm -f captura-parcial | Out-Null
}

Guardar "08_http_cabeceras_websocket.txt" {
    "### Handshake WebSocket a través de Nginx (HTTP/1.1 Upgrade -> 101)"
    curl.exe -s -i -N --max-time 3 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" "http://localhost/jupyter/api/events/subscribe?token=parcial2026"
    ""
    "### Respuesta del portal (cabeceras) a través de Nginx"
    curl.exe -s -D - -o NUL http://localhost/
    "### Keep-alive cliente: 3 peticiones sobre la MISMA conexión TCP"
    curl.exe -s -v -o NUL -o NUL -o NUL http://localhost/ http://localhost/grafana/api/health http://localhost/nginx-health 2>&1 | Select-String -Pattern "Connected to|Re-using|Connection #|HTTP/1.1 "
}

Guardar "09_conexiones_postgresql.txt" {
    # Una consulta vía Grafana abre/reutiliza su pool de conexiones antes de listar
    curl.exe -s -o NUL -u admin:AdminGrafana_2026 http://localhost/grafana/api/datasources/uid/pg-parcial/health
    docker compose exec -T database psql -U dba_admin -d joomla -c "SELECT usename, application_name, client_addr, client_port, state, backend_start FROM pg_stat_activity WHERE backend_type='client backend' ORDER BY backend_start"
    docker compose exec -T database sh -c "echo '### Sockets TCP en database (puerto 5432 = 0x1538)'; cat /proc/net/tcp | head -20"
}

Guardar "10_logs_muestra.txt" {
    "### Últimas líneas del log TSV de Nginx (volumen nginx_logs)"
    docker compose exec -T nginx tail -n 5 /var/log/nginx-parcial/access.log
    "### Últimas líneas del log TSV de Apache/Joomla (volumen joomla_logs)"
    docker compose exec -T joomla tail -n 5 /var/log/joomla/apache_access.log
    "### Los mismos datos leídos por PostgreSQL (file_fdw -> vista monitoreo.v_nginx_accesos)"
    docker compose exec -T database psql -U dba_admin -d joomla -c "SELECT ts, ip_origen, metodo, ruta, estado, upstream_addr, upstream_connect_s, peticiones_en_conexion, servicio FROM monitoreo.v_nginx_accesos ORDER BY ts DESC LIMIT 5"
}

Write-Host "Listo."
