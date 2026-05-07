# IOSUploaderDemo

此目录用于承载后续 iOS Simulator smoke 与宿主接入示例。

当前首版未提交完整独立 Demo App 工程，但已补齐可执行的 simulator smoke 脚本入口，以下目录仍承担这些用途：

1. 作为 `DataGatewayClient` 的最小接入样例。
2. 作为 iOS Simulator smoke 的承载目录。
3. 用于验证前后台切换、强杀恢复、断网恢复等端侧专项场景。

建议后续示例工程至少包含：

1. 使用 `DataGatewayClientConfig.recommended(...)` 初始化 SDK。
2. 使用 `ArchebaseDeviceInitializer.initDevice(deviceID:)` 写入 `archebase-config.json`。
3. 使用 `ArchebaseDeviceInitializer.reinitDevice(deviceID:)` 显式轮换配置。
4. 使用 `DataGatewayClient.fromArchebaseConfig(...)` 从配置文件构造上传 client。
5. 支持选择文件并发起 `upload(_:)`。
6. 支持订阅 `uploadEvents(_:)` 并显示阶段变化。
7. 支持列出 `listPendingUploads()` 返回的本地待恢复任务。
8. 支持调用 `resumeUpload(logicalUploadID:)`、`abortUpload(logicalUploadID:)`、`deleteLocalSnapshot(logicalUploadID:)`。

建议从 package 根目录执行模拟器 smoke 命令：

```bash
cd data-sdk
export DGW_LOCAL_AUTH_ENDPOINT='http://127.0.0.1:15055'
export DGW_LOCAL_GATEWAY_ENDPOINT='http://127.0.0.1:15053'
export DGW_LOCAL_INIT_ENDPOINT='http://127.0.0.1:15057'
export DGW_LOCAL_CREDENTIAL_BASE64='<credential_base64>'
export DGW_LOCAL_DEVICE_ID='<device_id>'
./Scripts/simulator_smoke.sh
```

该脚本默认执行 `SwiftDataGatewayClient-Package` scheme 上的本地联调 smoke，并显式启用 `xcodebuild` 测试超时：

1. `DGW_IOS_SMOKE_DESTINATION_TIMEOUT_SECONDS`，默认 `30`
2. `DGW_IOS_SMOKE_DEFAULT_TEST_TIMEOUT_SECONDS`，默认 `120`
3. `DGW_IOS_SMOKE_MAX_TEST_TIMEOUT_SECONDS`，默认 `300`
4. `DGW_IOS_SMOKE_TEST_ONE` / `DGW_IOS_SMOKE_TEST_TWO` 默认指向 `LocalStackHarnessTests` 两个 smoke case，`DGW_IOS_SMOKE_TEST_THREE` 默认指向 device initializer 配置写入 smoke，且测试标识必须带 `()`
5. `DGW_IOS_SMOKE_DERIVED_DATA_PATH` 可覆盖 `build-for-testing` 产物目录；脚本会自动 patch `.xctestrun`，确保 simulator 宿主进程拿到 `DGW_LOCAL_*` 环境变量

当前环境如缺少可用 iOS Simulator runtime / CoreSimulator 组件，脚本会在前置检查阶段直接失败，而不是无限等待。
