# 推代码到 GitHub（SSH 密钥方式，不发任何密码/token）

> 现状：设备码登录反复超时，改用 SSH 密钥。
> **不会往聊天里发任何密钥**，你只需要把下面这段公钥贴到 GitHub。

---

## 链路的实际状态（已实测）

```
你的电脑 ──SSH(22)──> 香港 VPS 103.119.2.243 ──> github.com:22   ✅ 通
```

测出来的结果是：

```
git@github.com: Permission denied (publickey).
```

**这正是对的结果** —— 说明网络完全通了，只是这把钥匙还没挂到你账号上。

> 为什么绕香港：国内直连 GitHub 的 443 会被掐（TCP 能连、TLS 断），22 端口也常被封。
> 现在走 SSH 到香港 VPS 再跳 GitHub，全程加密隧道，稳定。

---

## 你只需要做两件事

### ① 把公钥加到 GitHub（30 秒）

**公钥内容**（整行复制，别漏了开头结尾）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDSDw4/EhPT90JEek/3JD+uNuE6F2r5GjB6FuYeTYcvM lab-xiyo
```

操作步骤：

```
1. 在你已经登录的浏览器里打开：
   https://github.com/settings/ssh/new

2. Title 填：lab
3. Key 框里粘贴上面那一整行
4. 点 Add SSH key
```

> 如果那个页面打不开，说明你用的浏览器没走代理。
> 双击 `启动GitHub通道.cmd` 会打开一个带代理的 Edge，用它去开。

### ② 建一个空仓库（20 秒）

```
https://github.com/new
名字：xiyo-clone
选 Private
不要勾 Add README / .gitignore / license
点 Create repository
```

---

## 然后告诉我「好了」，剩下的我全做

我会执行：

```bash
# 1. 验证 SSH 登录
ssh -T git@github.com          # 期望: Hi <你的用户名>! You've successfully authenticated

# 2. 配置 remote 并推送
git remote add origin git@github.com:<你的用户名>/xiyo-clone.git
git push -u origin main

# 3. 确认 workflow 被触发
```

---

## 如果 ① 里的公钥你用起来不放心

那把钥匙是**只用于 GitHub 推送**的专用密钥，文件在：

```
xiyo-lab\tools\github_key        （私钥，留在本机）
xiyo-lab\tools\github_key.pub    （公钥，贴到 GitHub）
```

你可以随时在 https://github.com/settings/keys 里删掉它，删掉后这把钥匙立刻失效。
它没有你账号的密码，只能推送仓库代码（权限就是你给它的那个 key 的权限）。

---

## 备选：如果你更想用 Token

也可以走 Token 方式（更快，但要把 token 发给我一次）：

```
https://github.com/settings/tokens/new
Note: lab
勾选：repo（全部）
Generate token → 复制 ghp_xxxxx
```

把 token 发我，我用完立刻从 git 配置里删掉，并提醒你去 revoke。

**但我建议用 SSH 密钥**，不用把任何秘密发出来。
