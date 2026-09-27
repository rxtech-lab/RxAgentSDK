# RxAgentSDK Provider 扩展方案

## 目标

以千问为第一个验证对象，完成从模型 API 接入到原生 Coding Agent 接入，再把 RxCode 当前固定 Provider 注册方式改造成可扩展 Registry。

目标架构：

```text
RxCode UI / AppState
        ↓
SDKAgentBackend（RxCode 适配层）
        ↓
RxAgentSDK AgentClientRegistry
        ↓
AgentClient
        ├── ClaudeCodeClient
        ├── CodexClient
        ├── ACPClient
        ├── OpenAIChatClient
        └── QwenCodeClient
```

## 执行原则

1. Provider 协议、进程管理、事件解码、工具调用和权限逻辑放在 RxAgentSDK。
2. RxCode 只负责 Provider 注册、配置界面、Keychain、模型选择和产品状态展示。
3. 不在 `AppState`、Chat UI 或 `BackendSendRequest` 中加入千问专用字段。
4. 不复制一套新的 Agent Loop；兼容模型复用 `OpenAIChatClient`，原生 Harness 实现 `AgentClient`。
5. 先完成 SDK 测试，再接入 RxCode；每个阶段都必须可独立验证。
6. 保持旧 Claude/Codex/ACP 路径可用，直到新路径通过同场景回归测试。

## 阶段一：DashScope OpenAI-compatible 模型

### 目标

让 RxAgentSDK 可以通过 DashScope 兼容接口运行一个千问模型，完成文本、流式输出、Tool Calling、MCP 和取消验证。

### 允许修改

RxAgentSDK：

- `Sources/RxAgentLLM/OpenAIChatClient.swift`
- `Sources/RxAgentLLM/OpenAIWire.swift`
- `Sources/RxAgentCore/AgentEvent.swift`（仅在现有事件不足时）
- `Tests/RxAgentLLMTests/`
- 新增 Qwen 配置/测试辅助文件（只封装配置，不复制请求循环）

RxCode：

- `RxCode/Services/AgentSDK/SDKBackendFactory.swift`
- Provider 配置和 Keychain 入口
- 模型选择入口

### 必须验证

- DashScope endpoint 和 Bearer Token
- SSE 增量文本
- `tool_calls` 分片和参数解析
- MCP 工具发现、调用、结果回传
- 图片附件（目标模型支持时）
- `enable_thinking`、`reasoning_effort` 等参数通过 `extraBody` 或配置传入
- `stream_options.include_usage` 的 usage 解析
- 超时、HTTP 错误、模型错误、取消

### 完成标准

- SDK 测试覆盖协议解析和错误映射。
- 使用真实 DashScope 配置完成一次端到端运行。
- RxCode 可以选择该 Client 并显示文本、工具调用和错误。

### 禁止事项

- 不新增 `QwenStreamEvent`。
- 不把 DashScope 字段写入 RxCode 的通用请求模型。
- 不声称已经接入 Qwen Code Harness；本阶段只有模型 API。

## 阶段二：确认 Qwen Code Harness 接入方式

### 目标

确认 Qwen Code 的实际运行形态：ACP、JSON-RPC、stdin/stdout、HTTP，或只能通过现有 CLI 调用。

### 只做调查和最小验证

- 确认启动命令、版本、认证方式和中国区域 endpoint。
- 记录 session、turn、取消、恢复、权限和工具调用协议。
- 确认 MCP 接入方式。
- 确认是否有模型发现、thinking/reasoning、附件和 Skills。
- 优先判断是否可以直接使用 `ACPClient`。

### 输出物

新增一份短协议记录，至少包含：

```text
启动方式
输入格式
输出事件
session / turn 标识
工具调用格式
权限格式
取消方式
MCP 方式
错误格式
```

### 完成标准

- 得出“直接复用 ACPClient”或“必须新增 QwenCodeClient”的明确结论。
- 不在此阶段修改通用 Agent 模型。

## 阶段三：接入 Qwen Code 原生 Harness

### 目标

如果阶段二确认 Qwen Code 有独立协议，实现 `QwenCodeClient: AgentClient`，让 RxAgentSDK 调用 Qwen Code 自身的 Coding Agent Runtime。

### 允许修改

RxAgentSDK：

- `Sources/RxAgentClients/QwenCodeClient.swift`
- `Sources/RxAgentClients/` 下的协议解码和进程辅助文件
- `Sources/RxAgentCore/AgentEvent.swift`（仅补充通用事件）
- `Tests/RxAgentClientsTests/`

RxCode：

- 临时在 `SDKBackendFactory` 增加一个 Qwen Client 注册项
- 配置和启动参数传递
- 必要的显示名称和能力映射

### 统一映射

```text
Qwen text delta       → AgentEvent.textDelta
Qwen thinking         → AgentEvent.thinkingDelta
Qwen tool call        → toolCallStarted / toolCallInput
Qwen tool result      → toolCallResult
Qwen permission       → permissionRequested
Qwen usage            → usage
Qwen completed        → turnEnded
Qwen failure          → failed
```

### 完成标准

- Qwen Code 可完成读取、修改、运行测试的完整任务。
- 支持停止、错误、权限和 MCP。
- 同一任务可以在 RxCode 中看到完整事件和最终 Diff。
- 不破坏 Claude、Codex、ACP。

### 禁止事项

- 不将 Qwen Code 的内部事件直接暴露给 RxCode UI。
- 不在 RxCode 重写 Qwen Code 的工具循环。
- 不为了 Qwen 特性修改所有 Provider 的公共行为。

## 阶段四：动态 AgentClientRegistry

### 目标

消除 RxCode 对 Claude/Codex/ACP 的硬编码，使新增 Provider 主要只修改 RxAgentSDK。

### SDK 新增抽象

建议新增：

```swift
public struct AgentClientDescriptor: Sendable, Codable {
    public let id: AgentClientID
    public let displayName: String
    public let provider: AgentProvider
    public let capabilities: AgentCapabilities
}

public protocol AgentClientFactory: Sendable {
    var descriptor: AgentClientDescriptor { get }
    func makeClient(configuration: AgentClientConfiguration) async throws
        -> any AgentClient
}
```

Registry 应支持：

- 内置 Client 注册
- 配置驱动的 OpenAI-compatible Client
- ACP 动态 Client
- QwenCodeClient 等原生 Client
- 模型和 reasoning level 发现
- Provider 可用性检查

### RxCode 改造范围

- `SDKBackendFactory` 改为读取 Registry。
- 设置界面按 Descriptor 动态生成。
- Keychain 按 `AgentClientID` 隔离。
- 模型选择读取 `availableModels()`。
- 能力读取 `AgentCapabilities`，再明确映射到 RxCode 能力。
- 移动同步只保存配置标识，不同步明文密钥。

### 完成标准

新增一个测试 Provider 时：

```text
新增 SDK AgentClient + Factory + 测试
        ↓
RxCode 自动发现并显示
        ↓
无需新增 AppState Provider 分支
```

## 统一验收清单

每个 Provider 至少验证：

- [ ] 新建 session
- [ ] 恢复 session 或重放历史
- [ ] 流式文本
- [ ] thinking（如果支持）
- [ ] Tool Calling
- [ ] MCP
- [ ] 权限请求
- [ ] 取消
- [ ] 超时和错误
- [ ] 模型发现
- [ ] reasoning levels
- [ ] 文件修改和 Diff
- [ ] 测试命令执行
- [ ] RxCode 线程持久化
- [ ] 旧 Provider 回归

## 变更控制

如果实现过程中发现以下需求，应暂停并单独评估，不直接扩大本方案：

- 修改 RxCode 任务模型
- 修改通用 `AgentEvent` 语义
- 引入新的 UI 组件体系
- 引入新的远程服务或 Relay
- 将 Provider 逻辑复制到 RxCode
- 同时重构旧 Claude/Codex/ACP 代码

这些属于独立项目，不应混入千问 Provider 接入任务。
