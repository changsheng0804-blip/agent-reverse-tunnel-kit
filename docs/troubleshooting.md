# 排障手册

按现象查。所有条目都来自参考实测（见 README「实测记录」）。

## 隧道刚通就断 / 过一会儿连不上落点端口

- **最常见**：单发隧道随发起会话一起被回收。参考环境里单发隧道寿命约 46 秒：
  出站连接经平台代理时，代理连接的寿命绑在发起它的会话上。
  → 解法只有一个：用 `tunnel-keep.sh` 守夜人循环，并确认它本身是脱离会话启动的
  （`start_tunnel.sh` 已用 setsid + nohup 处理）。看 `tunnel-keep.log` 的重启次数能验证。
- 守夜人在跑但反复重启：看日志里 ssh 的报错。`ExitOnForwardFailure` 会让“落点端口被占用”
  直接失败退出再重试，表现为疯狂刷日志 → 换 REMOTE_PORT 或清掉占口的旧隧道。

## 本地连落点端口：Connection refused

顺序排查：
1. 落点上端口在听吗？`lsof -nP -iTCP:2222 -sTCP:LISTEN`（macOS）或 `ss -tln | grep 2222`。
   不在听 = 隧道没建起来，去智能体侧看守夜人日志。
2. 在听但连不上 = 隧道通到智能体，但智能体侧登录服务没在跑：
   智能体侧 `ss -tln | grep 2223`，没有就 `bash agent/start_server.sh`。
3. 两边都在听，就是这台机器的问题：先在本机自测登录服务（见下一条）。

## 登录服务本机自测

在智能体机器上：
```bash
ssh-keyscan -p 2223 127.0.0.1 | ssh-keygen -lf -   # 指纹应与 setup 打印的一致
ssh -i /tmp/wrongkey -p 2223 -o BatchMode=yes revtest@127.0.0.1 'echo hi'
# 期望: Permission denied (publickey). —— 说明服务在、纪律在
```
若错钥匙能进，立刻停下：授权名单或服务配置错了，不要继续打隧道。

## 改了 authorized_keys 不生效

Variant B（ssh_server.py）在**启动时**把名单读进内存。增删钥匙后必须重启服务：
找到监听 2223 的 pid 杀掉，再 `bash agent/start_server.sh`。
（调试时临时加的测试钥匙，用完务必删掉并重启，名单里只留正式那一条。）

## shell 提示 cannot set terminal process group / no job control

登录服务给 shell 分配了伪终端，但没把控制终端交给它。
无害（普通命令照常用），受影响的只有 Ctrl-Z、fg/bg 等作业控制。
本仓库 `ssh_server.py` 已修：会话进程在降权时同时 `setsid()` 并 `ioctl(0, TIOCSCTTY)`。
若你用的是别的简易 SSH 服务实现，照此补即可。

## 嵌套 SSH 验证时输出丢失

在智能体机器里再套一层 ssh 去验证“落点 → 隧道 → 自己”，
外层连接的收尾噪声（某些代理助手会在退出时报 Broken pipe）可能把内层输出吞掉，
造成“看起来失败”。判定标准：以**本地直连一层**的验证结果为准；
旁证看智能体侧 `server.log` 是否有 `auth OK` 与对应的 `exec:` 记录。

## apt 装 openssh-server 极慢或无候选

不要死等。直接用 Variant B（paramiko venv 自包含），功能与纪律完全等效，
且拆除更干净（删一个目录即可）。参考实测就是在 apt 停摆后改走 Variant B 完成的。

## 机器重启/被平台替换后门没了

预期行为：进程不跨重启（除非你自己把它注册成系统服务）。
工作目录与用户在家目录盘上一般保留，重新 `start_server.sh` + `start_tunnel.sh` 即恢复。
若连家目录都被重置，按 README 从 4.2 重走一遍，十分钟级。
