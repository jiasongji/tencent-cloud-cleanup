# 贡献指南

感谢你对本项目的关注！欢迎提交 Issue 和 Pull Request。

## 提交 Issue

- 清晰描述遇到的问题
- 提供操作系统版本、腾讯云产品类型（CVM/Lighthouse）
- 附上脚本执行输出或错误信息
- 脱敏处理后提交（不要包含 IP、密码等敏感信息）

## 提交 PR

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feature/your-feature`
3. 提交修改：`git commit -m '描述你的修改'`
4. 推送分支：`git push origin feature/your-feature`
5. 创建 Pull Request

## 修改脚本时请注意

- 保持脚本在 Debian/Ubuntu/CentOS 上的兼容性
- 所有输出使用中文
- 新增清理项需要同时在验证部分添加对应的检查
- 修改前请先在测试环境验证
