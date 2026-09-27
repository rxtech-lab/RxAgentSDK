# Qwen Code ACP 接入记录

## 当前结论

Qwen Code 官方提供 `qwen --acp` 入口，RxAgentSDK 阶段三直接复用现有
`ACPClient`，不新增一套 Qwen 专用 Agent Loop。

```text
RxAgentSDK
  └── QwenCodeFactory
        └── ACPClient
              └── qwen --acp
```

Qwen Code 自己负责模型、工具、权限、MCP 和会话上下文；SDK 只负责进程
生命周期、ACP JSON-RPC、事件归一化和 RxCode 适配。

## 启动配置

```text
command: qwen
arguments: --acp
model environment: QWEN_MODEL
authentication: Qwen Code 自己的 ~/.qwen 配置或环境变量
```

SDK 工厂入口：

```swift
let factory = QwenCodeFactory()
let client = try factory.makeClient(
    configuration: AgentClientConfiguration(clientID: .qwenCode)
)
```

## 协议验收

安装 Qwen Code 后，在工作目录执行：

```bash
qwen --acp
```

然后使用 RxAgentSDK 的 `QwenCodeFactory` 验证：

- `initialize`
- `session/new`
- `session/prompt`
- `session/update`
- `session/request_permission`
- `session/cancel`
- 文件读写请求
- MCP Server 能力协商
- 会话进程跨 turn 复用

当前开发机尚未发现 `qwen` 可执行文件，因此真实 ACP 会话仍需在安装
Qwen Code 后完成。SDK 编译测试不依赖本机安装 Qwen Code。
