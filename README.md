# 云端智能体反向隧道工具包（Agent Reverse Tunnel Kit）

让一个**云端智能体**（住在一台你进不去的云电脑/VM 里）主动向**你自己的机器**打一条反向 SSH 隧道，
于是你能从本地终端直接 SSH 登进它那台机器——就像它给你开了一道门。

本工具包来自一次真实复现：一个云端智能体运行在一台“只能主动出站、不能被连入”的
平台云电脑上，用本流程在约 20 分钟内完成了：智能体侧自建登录服务 → 主动打出反向隧道 →
本地电脑经隧道登入并执行命令，全链路验证通过。细节见文末「实测记录」。

---

## 1. 原理（一句话版）

智能体的机器通常**没有公网入口、你拨不进去，但它自己能往外连**。
让它做三件事，进的方向就被“出”带出来了：

1. 在自己机器里开一个 SSH 登录服务（只听本机回环地址）；
2. 把你本地机器的**公钥**放进它的授权名单，只认钥匙、不认密码；
3. 主动 SSH 到你的机器（落点），同时带一条反向转发：落点本机的某端口 → 它自己的登录服务端口。
   并用一个“守夜人”循环让这条隧道断了自动重连。

之后你在本地执行 `ssh -p 2222 revtest@127.0.0.1`，流量先到落点的 2222 端口，
顺隧道倒流回智能体机器的登录服务，你就进去了。

```
  你的电脑                落点（你的机器或跳板机）            智能体的云电脑
 ┌─────────┐   ssh -p2222   ┌──────────────┐   反向隧道     ┌────────────────┐
 │ 终端     │ ─────────────► │ 127.0.0.1:2222│ ═══════════► │ SSH服务 :2223   │
 │ +专用私钥 │                │ （只绑本机）   │ ◄═══════════ │ （只听回环）     │
 └─────────┘                └──────────────┘  智能体主动     │ 专用低权用户     │
                               ▲                连出并保活    └────────────────┘
                               └── 也可以与你的电脑是同一台（最常见）
```

## 2. 前提条件（缺一不可，先逐项验）

| # | 条件 | 怎么验 |
|---|------|--------|
| 1 | 智能体能在自己机器里**执行命令**（有 shell/终端工具） | 让它跑 `hostname; whoami` 并回给你看 |
| 2 | 它能**主动连到落点**（真出网：能 SSH/TCP 到你指定的机器，不只是“能浏览网页”） | 让它 `ssh -o ConnectTimeout=10 你@落点 echo ok` 或至少 `nc -vz 落点 22` |
| 3 | **后台进程能常驻**，或能放一个断线重连的循环脚本 | 让它 `setsid nohup sleep 600 &`，十分钟后问它进程还在不在 |
| 4 | 有一个**落点**：一台双方都够得着的机器 | 你的电脑装 Tailscale 等私网、或一台有公网 IP 的 VPS 跳板机都行 |
| 5 | **授权**：这台机器/账号是你有权这么做的 | 自己的专属智能体实例 = 装门；别人平台的产品沙盒 = 可能违反条款，先想清楚 |

第 5 条不是技术问题，但决定这件事的性质。技术动作完全相同，区别只在授权。

## 3. 安全边界（本工具包的默认姿势，不要放松）

- **零公网口**：智能体侧登录服务只听 `127.0.0.1`；隧道口在落点上默认也只绑落点的 `127.0.0.1`
  （OpenSSH 反向转发默认就是本机绑定，除非显式开 GatewayPorts——不要开）。
- **一把钥匙一扇门**：本地生成专用密钥对，私钥只留在本地，永不外传；智能体侧授权名单只放这一条。
- **专用低权用户**：登录用户是新建的低权账号（如 `revtest`），密码登录关闭、root 禁登、
  它进不了智能体自己的工作目录——你登进去的是“客房”，不是主卧。
- **可一键拆除**：所有东西收拢在一个目录 + 一个用户，`stop_all.sh --user` 全清。
- **先小后大**：先按临时实验跑通，再决定要不要常驻；常驻前逐项过 `docs/security-checklist.md`。

## 4. 完整流程

### 4.0 准备落点

落点就是你的电脑或一台跳板机，需要满足：智能体能 SSH 登入它。
即落点上要有一个账号，并把**智能体侧的公钥**加进落点的 `~/.ssh/authorized_keys`
（这是智能体 → 落点方向的钥匙，和 4.1 里你 → 智能体方向的钥匙是两把，别混）。
如果落点是你电脑且智能体出网受限，先按前提条件第 2 条实测连通再继续。

### 4.1 本地侧：生成你的专用钥匙

```bash
bash local/setup_local.sh agent-door
```

它会打印一行公钥。把这一行**交给智能体**（贴给它即可，这是公钥，不保密），
让它写进它那边的 `authorized_keys`。

### 4.2 智能体侧：建用户与登录服务

把本仓库给智能体，让它在自己机器上执行（或你按 `AGENT_INSTRUCTIONS.md` 把指令贴给它）：

```bash
cd agent
sudo bash setup.sh revtest "$HOME/revssh"
```

`setup.sh` 做四件事：建低权用户 `revtest`、建工作目录、生成主机钥匙并打印**主机指纹**、
装好 Variant B 需要的 paramiko（自包含 venv）。把主机指纹记下来，4.4 验证时要对。

然后把 4.1 的公钥写进授权名单（只有一行）：

```bash
echo 'ssh-ed25519 AAAA...（你的公钥整行）' > "$HOME/revssh/authorized_keys"
chmod 600 "$HOME/revssh/authorized_keys"
```

**登录服务二选一：**

- **Variant A（原生 sshd，优先）**：机器上有 openssh-server（或能装上）时用。
  把 `agent/sshd_config.template` 里的 `REVSSH_DIR`/`REVSSH_USER` 替换为实际值后：
  `/usr/sbin/sshd -f <该配置的绝对路径>`。
- **Variant B（自带 Python SSH 服务，实测用的就是这个）**：没有 sshd 也没关系。
  ```bash
  bash agent/start_server.sh    # 起在 127.0.0.1:2223，脱离当前会话常驻
  ss -tln | grep 2223           # 确认在听
  ```
  冒烟测试（在智能体机器本机上）：随便拿一把**错的**钥匙试登，应被拒：
  ```bash
  ssh-keygen -t ed25519 -N '' -f /tmp/wrongkey
  ssh -i /tmp/wrongkey -p 2223 -o BatchMode=yes revtest@127.0.0.1 'echo hi'
  # 期望输出: Permission denied (publickey).
  ```

### 4.3 智能体侧：打隧道（带守夜人）

```bash
cd agent
cp tunnel.env.example tunnel.env   # 按注释填：落点账号/IP、智能体登落点的钥匙、端口
bash start_tunnel.sh               # 启动守夜人循环（断了自动重连）
```

> **为什么必须有守夜人**：实测中单发一条隧道只活了约 46 秒——很多平台里，
> 智能体的出站连接寿命绑在发起它的会话/代理上，会话结束连接就被掐。
> 循环重连是让这道门“常开”的关键，不是可有可无的装饰。见 `docs/troubleshooting.md`。

### 4.4 本地侧：验证（全链路）

```bash
bash local/verify.sh agent-door 2222 revtest
```

期望输出类似：

```
REVERSE_LOGIN_OK
uid=1000(revtest) gid=1000(revtest) groups=1000(revtest)
<智能体机器的主机名>
/home/revtest
Ubuntu 24.04.x LTS
```

然后亲手进一次（交互式）：

```bash
ssh -i ~/.ssh/agent-door -p 2222 revtest@127.0.0.1
```

第一次连接会让你确认主机指纹，**必须和 4.2 里智能体侧打印的一致**，对上再输入 yes。
看到 `revtest@<主机名>:~$` 提示符，就是进去了。`exit` 退出。

### 4.5 日常使用与拆除

- 常用命令都可一条龙：`ssh -i ~/.ssh/agent-door -p 2222 revtest@127.0.0.1 '你要跑的命令'`。
- 隧道断了先看智能体侧 `tunnel-keep.log` 与 `server.log`（都在智能体的工作目录里）。
- 彻底拆除（智能体侧）：`bash agent/stop_all.sh --user`；本地删钥匙：`rm ~/.ssh/agent-door*`，
  并删 `~/.ssh/known_hosts` 里 `[127.0.0.1]:2222` 那一行。

## 5. 常见坑（全部来自实测，详见 docs/troubleshooting.md）

1. **单发隧道活不久**（约 46 秒被掐）→ 必须用守夜人循环（4.3）。
2. **机器没有 sshd、apt 又装不动** → 用 Variant B，不要卡死在装包上。
3. **改了 authorized_keys 没生效** → Variant B 是启动时读名单的，改完要重启服务。
4. **shell 报 `no job control in this shell`** → 登录服务没给 shell 分配控制终端；
   本工具包的 `ssh_server.py` 已包含修复（setsid + TIOCSCTTY）；老版本会这样，无害但难看。
5. **嵌套两层 SSH 时交互输出丢失** → 在智能体机器里再套一层 ssh 去验它自己的隧道，
   容易被会话回收掐断输出；以“本地直连一层”的结果为准，服务端日志可作旁证。
6. **落点 2222 被占用** → 换 `REMOTE_PORT`，三处（tunnel.env、连接命令、verify 参数）保持一致。

## 6. 实测记录（参考环境）

- 智能体侧：平台云电脑（Ubuntu 24.04，2 核 8G），Tailscale 仅出站客户端版（不能被连入），
  系统无 openssh-server、apt 软件源刷新极慢 → 采用 Variant B。
- 落点：一台 macOS 本地电脑（Tailscale 私网），智能体经平台代理以既有 SSH 通道登入该电脑并带 `-R`。
- 结果：本地电脑两次独立验证登入成功（身份 uid/gid/groups 全为 revtest），交互 shell 可用；
  守夜人上线后隧道零重启持续稳定；随后由操作者在本地终端直连验证成功。
- 同一方法的前提判定（第 2 节四条）对其他云端智能体同样适用：
  有 shell、能真出网、进程能常驻、有落点，缺一不可。

## 7. 文件清单

```
agent/
  setup.sh              建低权用户 + 工作目录 + 主机钥匙 + paramiko venv
  ssh_server.py         Variant B：自带 SSH 登录服务（只听回环、只认钥匙）
  sshd_config.template  Variant A：原生 sshd 配置模板
  start_server.sh       启动 Variant B 服务（脱离会话常驻）
  tunnel.env.example    隧道配置样例（落点/钥匙/端口）
  tunnel-keep.sh        守夜人：反向隧道断线重连循环
  start_tunnel.sh       启动守夜人
  stop_all.sh           一键拆除（--user 连用户一起删）
local/
  setup_local.sh        本地生成专用钥匙并打印公钥与连接命令
  verify.sh             本地一键全链路验证
AGENT_INSTRUCTIONS.md   可直接贴给云端智能体的执行指令（含安全边界）
docs/
  security-checklist.md 上线前安全检查表
  troubleshooting.md    排障手册
```
