#!/bin/bash
# ============================================================================
# demo_auto.sh — VPN 实验全自动演示驱动脚本（在宿主机上运行）
#
# 用法: bash demo_auto.sh
#       可从任意目录运行（脚本会自动切换到自身所在目录）。
# 作用: 按顺序自动执行全部 10 个测试项，输出解说与命令结果，步间停顿 2~3 秒。
#       使用者只需运行本脚本并开启屏幕录制。
#
# 测试项:
#   1. 启动容器           6. 多客户端并发测试 (fork + pipe)
#   2. 隧道建立前测试      7. 隧道中断测试
#   3. 隧道创建           8. 大数据包测试
#   4. Ping 测试          9. TLS 配置
#   5. Telnet 测试        10. 中间人攻击测试
# ============================================================================
set -u

# 切换到脚本所在目录，保证相对路径（ca.crt、volumes/...）始终可用
cd "$(dirname "$0")" || exit 1

SRV=server-10.0.2.8-192.168.60.1
CLI=client-10.0.2.5
CL2=client-10.0.2.6
HST=host-192.168.60.101
MITM=mitm-10.0.2.9-192.168.60.2

# 动态解析两个 docker 网桥接口名（网络重建后也能正确抓到）
BR_102="br-$(docker network inspect net-10.0.2.0 --format '{{.Id}}' | cut -c1-12)"
BR_60="br-$(docker network inspect net-192.168.60.0 --format '{{.Id}}' | cut -c1-12)"

# 查找容器内网卡对应的宿主侧 veth 接口名（该内核的 bridge master 抓不到转发帧，须抓 veth）
# 用法: host_veth <容器名> <容器内IP>
host_veth() {
    local ifname ifidx v
    ifname=$(docker exec "$1" bash -c "ip -o addr show | awk '/$2\\// {print \$2; exit}'")
    ifidx=$(docker exec "$1" cat "/sys/class/net/$ifname/ifindex")
    for v in /sys/class/net/veth*/; do
        if [ "$(cat "${v}iflink" 2>/dev/null)" = "$ifidx" ]; then
            basename "$v"
            return
        fi
    done
}

G='\033[1;32m'   # 绿色加粗（步骤标题）
B='\033[1;36m'   # 青色加粗（解说）
N='\033[0m'

step()  { echo -e "\n${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
          echo -e "${G}【$1】${N}"
          echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }
say()   { echo -e "${B}$*${N}"; }
run()   { echo -e "\$ $*"; "$@"; }

# 防止残留进程干扰：清理容器内的 VPN 进程
for c in "$SRV" "$CLI"; do
  docker exec "$c" pkill -f "[v]pnserver.py" 2>/dev/null
  docker exec "$c" pkill -f "[v]pnclient1.py" 2>/dev/null
done
docker exec "$CL2" pkill -f "[v]pnclient2.py" 2>/dev/null
docker exec "$CLI" pkill -f "[t]elnet_auto.py" 2>/dev/null

# ──────────────────────────────────────────────────────────────────────────
step "1/10 启动容器"
say "重启本次演示涉及的容器：VPN 服务器、两台客户端、私网主机"
say "（重启会重建各容器的 /etc/hosts 域名解析与网络配置）："
docker restart "$SRV" "$CLI" "$CL2" "$HST"
sleep 8
say "确认容器已启动、网络地址正确："
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E "10.0.2.5|10.0.2.6|10.0.2.8|192.168.60.101"
say "确保服务器容器内存在测试用户 vpntest（用于客户端认证）："
docker exec "$SRV" bash -c 'useradd -m vpntest 2>/dev/null; echo "vpntest:test1234" | chpasswd && id vpntest | cut -d" " -f1-3'
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "2/10 隧道建立前测试"
say "查看客户端的路由表：只有 10.0.2.0/24 直连路由，没有到私网 192.168.60.0/24 的路由。"
run docker exec "$CLI" ip route
sleep 2
say "尝试从客户端 Ping 私网主机 192.168.60.101 —— 应无法连通（网络隔离）："
run docker exec "$CLI" ping -c 2 -W 2 192.168.60.101
say "结果：100% 丢包。客户端与私网主机不在同一网络，且没有可达路由，处于隔离状态。"
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "3/10 隧道创建"
say "第一步：在 VPN 服务器上运行一键配置脚本（开启 IP 转发、创建隧道接口 tun0），"
say "        然后启动 VPN 服务端程序（监听 443 端口，TLS 加密隧道）："
run docker exec "$SRV" /volumes/vpn_setup.sh server
docker exec -d "$SRV" bash -c 'python3 -u /volumes/vpnserver.py > /tmp/vpnserver.log 2>&1'
sleep 3
run docker exec "$SRV" cat /tmp/vpnserver.log
sleep 2
say "第二步：配置私网主机 Host_V 的默认路由（指向 VPN 服务器 192.168.60.1）："
run docker exec "$HST" /volumes/vpn_setup.sh host
sleep 2
say "第三步：配置客户端（创建 tun0、添加 192.168.60.0/24 走隧道的路由），"
say "        然后启动客户端程序，输入用户名 vpntest 与密码（密码输入使用 getpass，无回显）："
run docker exec "$CLI" /volumes/vpn_setup.sh client1
docker exec -d "$CLI" bash -c 'printf "vpntest\ntest1234\n" | python3 -u /volumes/vpnclient1.py vpndengserver.com > /tmp/vpnclient1.log 2>&1'
sleep 4
run docker exec "$CLI" grep -E "Login" /tmp/vpnclient1.log
sleep 2
say "隧道建立后客户端的新增路由（192.168.60.0/24 dev tun0）："
run docker exec "$CLI" ip route show 192.168.60.0/24
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "4/10 Ping 测试"
say "客户端 Ping 私网主机，流量经 TLS 隧道转发："
run docker exec "$CLI" ping -c 3 192.168.60.101
sleep 2
say "抓包验证加密性：在客户端物理网卡所在链路（$BR_102）上抓取流量——"
say "先抓 ICMP（5 秒窗口）：若显示 0 个 ICMP 包，说明明文 ICMP 没有出现在物理链路上："
ICMP_CAP=$(timeout 5 tshark -i "$BR_102" -f "icmp" -c 5 2>/dev/null)
echo "$ICMP_CAP" | head -3
echo ">>> 5 秒内捕获 ICMP 包数: $(echo "$ICMP_CAP" | grep -cE ' [0-9]+\.[0-9]+ +IP ')（应为 0）"
sleep 2
say "再抓 443 端口（TLS 隧道）：ping 期间可见 TLS 记录（Client Hello / Application Data）："
nohup tshark -i "$BR_102" -f "tcp port 443" -c 6 > /tmp/tls_cap.txt 2>&1 &
sleep 1
run docker exec "$CLI" ping -c 3 192.168.60.101 > /dev/null
sleep 4
cat /tmp/tls_cap.txt | head -8
say "结论：物理链路上只有加密的 TLS 流量，没有明文 ICMP —— 隧道加密生效。"
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "5/10 Telnet 测试"
say "客户端通过隧道 Telnet 登录私网主机 Host_V（用户 seed），执行 id 命令，"
say "应用层交互正常，且整个会话的底层传输都被 TLS 加密保护："
run docker exec "$CLI" python3 /volumes/telnet_auto.py login
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "6/10 多客户端并发测试（fork + pipe）"
say "加分项演示：服务器主进程用 fork() 为每个客户端创建独立子进程，"
say "父子进程之间用 pipe() 建立单向管道，把 TUN 收到的反向数据包交给对应客户端。"
say "第二台客户端（10.0.2.6）接入同一 VPN 服务器："
run docker exec "$CL2" /volumes/vpn_setup.sh client2
docker exec -d "$CL2" bash -c 'printf "vpntest\ntest1234\n" | python3 -u /volumes/vpnclient2.py vpndengserver.com > /tmp/vpnclient2.log 2>&1'
sleep 4
run docker exec "$CL2" grep -E "Login" /tmp/vpnclient2.log
sleep 2
say "服务器进程树：1 个父进程 + 每个客户端 1 个子进程（fork 结果，两个客户端共存）："
run docker exec "$SRV" pgrep -a python3
sleep 2
say "查看最新子进程打开的文件描述符，可见 pipe（管道）与 socket、tun 三者，"
say "管道即父进程传递反向数据包的通道："
CHILD_PID=$(docker exec "$SRV" pgrep -x python3 | tail -1)
run docker exec "$SRV" bash -c "ls -l /proc/$CHILD_PID/fd | grep -E 'pipe|socket'"
sleep 2
say "两台客户端同时向私网主机发送 ping —— 并发隧道互不干扰："
( docker exec "$CLI" ping -c 3 192.168.60.101 2>&1 | tail -2 &
  docker exec "$CL2" ping -c 3 192.168.60.101 2>&1 | tail -2 &
  wait )
sleep 2
say "断开第二台客户端：服务器父进程通过 waitpid 回收其子进程，进程树恢复为 1+1："
run docker exec "$CL2" pkill -f "[v]pnclient2.py"
sleep 2
run docker exec "$SRV" pgrep -a python3
sleep 2

step "7/10 隧道中断测试"
say "先在后台建立一个自动 Telnet 会话（登录 Host_V，保持活跃）："
docker exec -d "$CLI" bash -c 'rm -f /tmp/vpn_killed; python3 /volumes/telnet_auto.py interrupt > /tmp/telnet_demo.log 2>&1'
sleep 12
run docker exec "$CLI" tail -4 /tmp/telnet_demo.log
sleep 1
say "Telnet 会话保持期间，强制停止 VPN 服务端程序："
run docker exec "$SRV" pkill -f "[v]pnserver.py"
sleep 2
say "客户端程序检测到隧道断开，自动打印 Server closed 并退出："
run docker exec "$CLI" tail -1 /tmp/vpnclient1.log
sleep 2
say "现在在旧的 Telnet 会话中输入命令 —— 只有本地回显，无任何响应："
docker exec "$CLI" touch /tmp/vpn_killed
sleep 10
run docker exec "$CLI" tail -5 /tmp/telnet_demo.log
sleep 1
say "重启 VPN 服务端与客户端程序恢复隧道："
docker exec -d "$SRV" bash -c 'python3 -u /volumes/vpnserver.py > /tmp/vpnserver.log 2>&1'
sleep 2
docker exec -d "$CLI" bash -c 'printf "vpntest\ntest1234\n" | python3 -u /volumes/vpnclient1.py vpndengserver.com > /tmp/vpnclient1.log 2>&1'
sleep 4
run docker exec "$CLI" grep -E "Login" /tmp/vpnclient1.log
say "旧的 Telnet 会话不会自动恢复（底层 TCP 连接已断裂、无应用层心跳保活），"
say "必须重新发起连接 —— 重新 Telnet 登录成功："
run docker exec "$CLI" python3 /volumes/telnet_auto.py login
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "8/10 大数据包测试"
say "发送 3028 字节的大包（ping -s 3000）：第一包为 PMTU 探测（DF 置位），"
say "隧道服务器转发到 MTU 1500 的私网时无法分片，回送 ICMP Frag needed 错误："
run docker exec "$CLI" ping -c 3 -s 3000 192.168.60.101
sleep 2
say "使用 -M want 允许分片：大包被切成 IP 分片传输，0% 丢包，证明程序不截断大包："
run docker exec "$CLI" ping -c 3 -s 3000 -M want 192.168.60.101
sleep 2
say "在私网链路上抓包，观察 IP 分片现象（一个 3028 字节的包被切成多个 1480 字节的分片）："
VETH_60=$(host_veth "$SRV" "192.168.60.1")
say "（抓包点：VPN 服务器私网网卡的宿主侧接口 $VETH_60）"
timeout 20 tshark -i "$VETH_60" -f "icmp" -c 10 > /tmp/frag_cap.txt 2>&1 &
sleep 3
run docker exec "$CLI" ping -c 3 -s 3000 -M want 192.168.60.101 > /dev/null
sleep 4
cat /tmp/frag_cap.txt | head -10
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "9/10 TLS 配置"
say "展示证书体系：用 openssl 验证服务器证书由自建 CA 签发（证书链校验通过）："
run openssl verify -CAfile ca.crt volumes/crt/server-certs/vpn.crt
sleep 1
say "服务器证书的主体、签发者与 SAN（主机名校验依据）："
run openssl x509 -in volumes/crt/server-certs/vpn.crt -noout -subject -issuer -ext subjectAltName
sleep 1
say "客户端信任库：CA 证书 + subject_hash 符号链接（capath 加载方式）："
run ls -l volumes/crt/client-certs/
sleep 1
say "代码中的 TLS 关键配置（客户端三步证书验证）："
run grep -n "CERT_REQUIRED\|check_hostname\|server_hostname=hostname\|Certificate failed" volumes/vpnclient1.py | head -5
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "10/10 中间人攻击测试"
say "攻击准备：在 MITM 主机(10.0.2.9)上用自签名伪造证书架设假冒的 TLS 服务器，"
say "伪造证书的 CN 与真实服务器相同（vpndengserver.com）："
docker start "$MITM" > /dev/null 2>&1
sleep 3
docker exec "$MITM" pkill -f "[s]_server" 2>/dev/null
docker exec "$MITM" bash -c 'rm -f /tmp/fake.key /tmp/fake.crt; \
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/fake.key -out /tmp/fake.crt -nodes \
  -subj "/CN=vpndengserver.com" -days 1 2>/dev/null && \
  nohup openssl s_server -accept 443 -cert /tmp/fake.crt -key /tmp/fake.key -quiet >/dev/null 2>&1 &'
sleep 2
say "攻击实施：修改客户端 /etc/hosts，把域名 vpndengserver.com 重定向到伪造服务器"
say "（先移除原有解析条目，再写入伪造服务器的地址 10.0.2.9）："
run docker exec "$CLI" bash -c 'grep -v vpndengserver /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts && echo "10.0.2.9 vpndengserver.com" >> /etc/hosts; grep vpndengserver /etc/hosts'
sleep 1
say "客户端连接 —— TLS 证书链校验失败（伪造证书不是我们的 CA 签发的）："
run docker exec "$CLI" bash -c 'printf "vpntest\ntest1234\n" | timeout 15 python3 -u /volumes/vpnclient1.py vpndengserver.com 2>/dev/null; echo "客户端退出码: $?"'
sleep 2
say "结论：客户端在输入用户名密码之前就终止握手并安全退出，未泄露任何凭据。"
say "清理：恢复 /etc/hosts（还原真实服务器解析），停止伪造服务器："
run docker exec "$CLI" bash -c 'grep -v vpndengserver /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts && echo "10.0.2.8 vpndengserver.com" >> /etc/hosts; grep vpndengserver /etc/hosts'
docker exec "$MITM" pkill -f "[s]_server" 2>/dev/null
sleep 2

# ──────────────────────────────────────────────────────────────────────────
step "演示结束"
say "全部 10 个测试项演示完毕："
say "  1. 启动容器           2. 隧道建立前测试     3. 隧道创建"
say "  4. Ping 测试          5. Telnet 测试        6. 多客户端并发(fork+pipe)"
say "  7. 隧道中断测试       8. 大数据包测试       9. TLS 配置"
say "  10. 中间人攻击测试"
echo
