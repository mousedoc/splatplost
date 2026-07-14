# Splatplost

[English](readme.md)

Splatplost 是一个基于 [libnxctrl](https://github.com/Victrid/libnxctrl) 的斯普拉遁投稿绘图器。它可以使用 Linux 蓝牙、Windows/Linux 上兼容的 USB 串口适配器，或远程 Linux 后端来驱动控制器；优化后的绘图算法最多可节省约三分之一的打印时间。

## 基本用法

### 安装

Splatplost 现在支持 Windows 和 Linux。图像规划可以在两个平台上运行。Windows 绘图需要兼容的 Splatplost USB 串口适配器，或者连接到 Linux 上运行的远程 `libnxctrl` 服务。Windows 不能直接使用基于 BlueZ 的 `nxbt` 蓝牙后端，普通 USB 数据线也不能替代控制器模拟适配器。

Windows 用户可以从 GitHub Actions 下载 `splatplost-windows-x64` 构建产物，解压后双击 `splatplost.exe` 启动图形界面，无需安装 Python。在界面中选择图片、生成路径，然后选择 USB 或 Remote 后端连接 Switch。

从源码安装 Windows 版本：

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install .
```

Linux 蓝牙后端仍然需要 root 权限：

由于操作蓝牙适配器需要 root 权限，你需要使用`sudo`或 root 用户运行相关命令。

```bash
sudo python3 -m pip install ".[bluetooth]"
```

这将自动安装所需的依赖。

如果你需要更新软件，可以使用`pip install --upgrade splatplost`。

### 使用

启动图形界面：

```bash
sudo splatplost
```

在图形界面中选择一张 320 x 120 图片并点击 **Load** 生成路径。选择斯普拉遁版本和控制器后端，再点击 **Connect to Switch** 并按照配对对话框操作。选择需要处理的图像区块后，点击 **Draw selected** 或 **Erase selected**。

## 需要帮助/遇到问题/功能请求

点击上方的 “Issue” 按钮，并提交一个 Issue。

碰到手柄连接和配对问题时，请在 [libnxctrl](https://github.com/Victrid/libnxctrl) 提交 Issue。

## 贡献



## 许可证

本项目基于 libnxctrl ，故采用 GPLv3 发布。
