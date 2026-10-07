# 安装与本机配置

此项目从公开源码生成快捷指令，配置单独存放在每台 Mac。本仓库不分发个人签名的快捷指令文件。

## 1. 检查环境

- macOS 27 的快捷指令支持 Wi-Fi 自动化；本项目界面和格式核对环境为 macOS 27.0.1。更早系统不在支持范围内。
- 确认自己有修改网络设置的管理员权限。
- 使用 `connect` / `disconnect` 时，先安装并配置 Shadowrocket，确认能在快捷指令中找到其“连接 VPN”“断开 VPN”动作。此项目不设置代理节点或订阅。
- 不使用 Shadowrocket 时，将所有 `shadowrocket` 设为 `keep`，并删除导入流程中的两个 Shadowrocket 动作；保留其余分支即可。

## 2. 下载源码并创建配置

在 GitHub 选择 **Code → Download ZIP** 并解压，或使用 Git：

```sh
git clone https://github.com/LXGVENICE/macos-wifi-switcher.git
cd macos-wifi-switcher
sh tools/install-config.sh
open -e /Users/Shared/WiFiSwitchConfig/config.json
```

安装脚本只复制示例文件，不改动网络；已存在的 `config.json` 会保留。新目录权限为 `700`，新配置文件权限为 `600`。

把 `Home-Example`、`Office-Example` 换成实际 SSID，固定地址、掩码、网关和 DNS 也必须换成本机需要的值。配置示例使用文档专用地址，不能直接用在真实网络。每台 Mac 的固定 IP 应不同。

不需要固定地址时，可将对应 `join.mode` 设为 `auto`，并删掉 `ip`、`subnetMask`、`router`、`dns` 四项。不要改动全局 `default.disconnect` 的 `auto + keep`。

读取格式检查，不会执行网络操作：

```sh
plutil -convert xml1 -o /dev/null /Users/Shared/WiFiSwitchConfig/config.json
```

检查通过仅说明格式能读取；地址是否适用于实际网络仍需由你确认。

## 3. 生成并导入快捷指令

只生成未签名文件，可离线执行：

```sh
sh tools/build.sh
```

macOS 导入通常需要签名。需要导入时执行：

```sh
sh tools/build.sh --sign
open dist/WiFi-Switch.shortcut
```

点击“添加快捷指令”。产物名称为 **WiFi Switch**；它包含完整动作与脚本，但没有自动化触发条件。此时还不会因 Wi-Fi 变化自行运行。

签名采用 `anyone` 模式。Apple 的签名服务会接收生成的快捷指令以验证；构建脚本只读取仓库中的公开源码，不读取本机 `config.json`。`people-who-know-me` 模式会包含联系人信息，本项目不使用该模式。详见 [Apple 的签名说明](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac)。

不希望使用签名服务时，可以新建快捷指令，按[动作搭建表](ACTIONS.md)复制脚本并连接变量，不运行构建的签名步骤。

## 4. 核对目录与权限

1. 打开 **WiFi Switch**。顶部“文本”应为 `/Users/Shared/WiFiSwitchConfig`，随后设为“配置目录”变量。自定义位置时，修改这一个文本值，并把配置放入该目录。
2. 每个“运行 Shell 脚本”动作都使用 `/bin/sh`、输入“作为参数”、勾选“以管理员身份运行”。不要改成 stdin。
3. 在 **快捷指令 → 设置 → 高级** 开启“允许运行脚本”。[Apple 操作说明](https://support.apple.com/guide/shortcuts-mac/advanced-shortcuts-settings-apdfeb05586f/mac)
4. 首次手动运行前先确认配置正确，并在可接受断网时进行。按系统提示授权脚本、Wi-Fi 名称和 Shadowrocket。Wi-Fi 名称不可用时，检查系统隐私设置中快捷指令的相关权限。
5. 如果需要锁屏后运行，在快捷指令详情的“隐私”中允许锁定时运行。

`current-run` 和 `apply.lock` 会在首次运行时创建。不要复制其他电脑的这两个文件，也不要在任务运行期间删除它们。

## 5. 添加自动化

完成配置和首次授权后，在 **WiFi Switch** 编辑器添加自动化触发条件：

- 触发：**Wi-Fi**。
- 网络：**任何网络**。
- 模式：**已加入或断开连接**。
- 关闭“运行前询问”（若界面显示该选项）。保留连接中断后运行。
- 在“自动化”列表确认该项已开启。

macOS 27 可通过菜单 **编辑 → 自动化** 给已有快捷指令添加触发条件；也可使用编辑器右侧的“自动化”操作库。[Apple 添加自动化说明](https://support.apple.com/guide/shortcuts-mac/add-automations-apdfbdbd7123/mac)

使用一个统一触发器即可。停用先前的加入、断开网络脚本，以免多个独立流程修改同一个网络服务。

## 6. 自行验证

依次验证已配置的手动网络、已配置的自动网络、未配置网络、完全断开四种状态。检查系统网络设置与 VPN 状态是否符合配置。`keep` 表示保持原状态，因此离开家庭 Wi-Fi 后，不会自动恢复此前的 VPN 连接。

若无法取得 Wi-Fi 名称或连接持续变化，流程最多尝试三次后停止。`STALE` 表示已有更新任务接管，是正常退出。

## 更新、停用与恢复

- 修改配置：下次触发时生效；一次运行使用开始时读取的配置快照。
- 更新源码：重新构建、导入后核对目录和权限；停用旧快捷指令的自动化，只保留一个启用的版本。
- 多台 Mac：各自准备第 3 版本机配置；快捷指令可以同步，本机地址不应共用。
- 停用：关闭自动化开关。关闭或删除快捷指令不会主动恢复已写入的网络设置；如需恢复，在系统设置中将 IPv4 改为 DHCP、DNS 改为自动、IPv6 改为自动。
