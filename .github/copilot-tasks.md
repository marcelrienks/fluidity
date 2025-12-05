# Fluidity Copilot Task Prompts

Named task prompts for common repetitive workflows in Fluidity. Reference these by name when working with Copilot.

---

## Task: `build-local`
**Description**: Build Fluidity server and agent binaries for the current platform

**Steps**:
1. Verify Go 1.23+ is installed: `go version`
2. Navigate to project root
3. Run build script: `./scripts/build-core.sh`
4. Verify binaries exist: `ls -la ./build/fluidity-server ./build/fluidity-agent`
5. Test binaries respond to help: `./build/fluidity-server -h`

**Common Options**:
- `./scripts/build-core.sh --linux` - Build for Linux (Docker/deployment)
- `./scripts/build-core.sh --clean` - Clean before building
- `./scripts/build-core.sh --agent` - Build only agent

---

## Task: `build-docker`
**Description**: Build Docker containers for server and agent

**Steps**:
1. Verify Docker is running
2. Run Docker build: `./scripts/build-docker.sh`
3. Verify images were created: `docker images | grep fluidity`
4. Test server image: `docker run --rm fluidity-server:latest -h`
5. Test agent image: `docker run --rm fluidity-agent:latest -h`

**Common Options**:
- `./scripts/build-docker.sh --push` - Build and push to registry
- `./scripts/build-docker.sh --no-cache` - Force rebuild without cache

---

## Task: `test-local`
**Description**: Run tests on native binaries without Docker

**Prerequisites**:
- Server and agent binaries built (`build-local` task)
- mTLS certificates generated: `./scripts/generate-certs.sh`
- Port 8080 (agent) and 8443 (server) available

**Steps**:
1. Start test: `./scripts/test-local.sh`
2. Script will:
   - Start server in background
   - Start agent in background
   - Run test requests through tunnel
   - Collect metrics and logs
3. Review output for success/failure
4. Check logs: `cat logs/server.log` and `cat logs/agent.log`

**Common Options**:
- `./scripts/test-local.sh --skip-build` - Skip rebuild, use existing binaries
- `./scripts/test-local.sh --test-url "https://api.example.com/test"` - Custom test URL

---

## Task: `test-docker`
**Description**: Run containerized tests with Docker Compose

**Prerequisites**:
- Docker running
- Docker images built (`build-docker` task)

**Steps**:
1. Run docker tests: `./scripts/test-docker.sh`
2. Script will:
   - Start server and agent containers via Docker Compose
   - Run tunnel tests
   - Capture container logs
   - Clean up containers
3. Review output and logs
4. Check container logs: `docker-compose logs`

**Common Options**:
- `./scripts/test-docker.sh --keep-running` - Leave containers running for debugging
- `./scripts/test-docker.sh --verbose` - Verbose logging

---

## Task: `generate-certs`
**Description**: Generate mTLS certificates for local development

**Steps**:
1. Navigate to project root
2. Run certificate generation: `./scripts/generate-certs.sh`
3. Verify certificates created:
   ```bash
   ls -la certs/
   # Should show: ca-cert.pem, server-key.pem, server-cert.pem, 
   #             client-key.pem, client-cert.pem
   ```
4. Check certificate validity: `openssl x509 -in certs/server-cert.pem -text -noout`

**Notes**:
- Certificates are git-ignored (in `.gitignore`)
- For production: Use proper certificate management (AWS Secrets Manager, etc.)
- Certificates expire after 365 days by default
- Regenerate if certificates are missing: `./scripts/generate-certs.sh --force`

---

## Task: `run-server-local`
**Description**: Start Fluidity server locally for development/testing

**Prerequisites**:
- Binaries built: `build-local` task
- Certificates generated: `generate-certs` task
- Port 8443 available

**Steps**:
1. Build: `./scripts/build-core.sh`
2. Generate certs: `./scripts/generate-certs.sh`
3. Start server: `./build/fluidity-server -config configs/server.local.yaml`
4. Verify server started:
   - Check logs for "Server started listening on :8443"
   - Server should be ready for agent connections

**Configuration**:
- Config file: `configs/server.local.yaml`
- Edit to change ports, log levels, metrics settings
- Use environment variables: `SERVER_PORT=9443 ./build/fluidity-server ...`

**Stopping**:
- Press Ctrl+C in the terminal

---

## Task: `run-agent-local`
**Description**: Start Fluidity agent locally for development/testing

**Prerequisites**:
- Server running: `run-server-local` task
- Binaries built: `build-local` task
- Certificates generated: `generate-certs` task
- Port 8080 available

**Steps**:
1. In new terminal, build: `./scripts/build-core.sh`
2. Start agent: `./build/fluidity-agent -config configs/agent.local.yaml`
3. Verify agent started:
   - Check logs for "Agent connected to server"
   - Agent should establish tunnel to server
4. Test tunnel: `curl http://localhost:8080/get`

**Configuration**:
- Config file: `configs/agent.local.yaml`
- Set `server_address` to match your server location
- Edit to change ports, log levels
- Use environment variables: `AGENT_PORT=9080 ./build/fluidity-agent ...`

**Stopping**:
- Press Ctrl+C in the terminal

---

## Task: `run-full-dev-stack`
**Description**: Start complete local development environment (server + agent)

**Prerequisites**:
- Port 8080 and 8443 available
- Two terminal windows

**Steps**:
1. Terminal 1 - Build everything:
   ```bash
   ./scripts/generate-certs.sh
   ./scripts/build-core.sh
   ```

2. Terminal 1 - Start server:
   ```bash
   ./build/fluidity-server -config configs/server.local.yaml
   ```
   
3. Terminal 2 - Start agent:
   ```bash
   ./build/fluidity-agent -config configs/agent.local.yaml
   ```

4. Terminal 3 (optional) - Test tunnel:
   ```bash
   curl http://localhost:8080/get
   curl http://localhost:8080/post -X POST -d '{"test": "data"}'
   ```

**Cleanup**:
- Stop both Terminal 1 and Terminal 2 (Ctrl+C)
- Optionally remove logs: `rm -rf logs/`

---

## Task: `add-go-dependency`
**Description**: Add a new Go dependency to the project

**Steps**:
1. Add import in your code: `import "github.com/user/package"`
2. Download and vendor dependency: `go mod tidy`
3. Verify dependency added: `grep "github.com/user/package" go.mod`
4. Run tests to ensure compatibility: `go test ./...`
5. Commit changes: `git add go.mod go.sum && git commit -m "Add github.com/user/package dependency"`

**Notes**:
- Always run `go mod tidy` after adding imports
- Keep dependencies up to date: `go get -u ./...`
- Review breaking changes before updating

---

## Task: `fix-go-lint`
**Description**: Fix Go code linting issues

**Steps**:
1. Run linter: `golangci-lint run ./...`
2. Review reported issues
3. For auto-fixable issues: `golangci-lint run --fix ./...`
4. For manual fixes:
   - Follow standard Go conventions
   - Run `gofmt -w .` to auto-format
   - Address any remaining linter warnings
5. Verify fixes: `golangci-lint run ./...`

**Common Issues**:
- `unused`: Remove unused variables/functions
- `ineffectual assignment`: Remove unnecessary assignments
- `error strings should not be capitalized`: Fix error message casing
- `exported function without comment`: Add godoc comments

---

## Task: `run-go-tests`
**Description**: Run all Go tests in the project

**Steps**:
1. Run tests: `go test ./...`
2. For verbose output: `go test -v ./...`
3. For coverage: `go test -cover ./...`
4. For detailed coverage report: `go test -coverprofile=coverage.out ./... && go tool cover -html=coverage.out`
5. Review results and fix any failures

**Common Options**:
- `go test -run TestName ./...` - Run specific test
- `go test -short ./...` - Skip long-running tests
- `go test -timeout 30s ./...` - Set test timeout

---

## Task: `check-security`
**Description**: Verify no secrets are committed to the codebase

**Steps**:
1. Check for common patterns: `grep -r "password\|secret\|api_key\|token" --include="*.go" --include="*.yaml" --include="*.json"`
2. Verify `.gitignore` includes sensitive files:
   - `certs/` (certificates)
   - `*.key` (private keys)
   - `.env` files
   - `logs/`
3. Check for hardcoded AWS credentials: `grep -r "AKIA\|aws_access_key" --include="*.go"`
4. Verify config files don't contain secrets: `cat configs/*.yaml | grep -i secret`
5. If secrets found, use `git filter-branch` or `git-crypt` to clean history

---

## Task: `deploy-local-docker`
**Description**: Deploy and run Fluidity locally using Docker Compose

**Prerequisites**:
- Docker and Docker Compose installed
- Images built: `build-docker` task

**Steps**:
1. Build images: `./scripts/build-docker.sh`
2. Start with Docker Compose: `docker-compose up -d`
3. Verify containers running: `docker-compose ps`
4. Check logs: `docker-compose logs -f`
5. Test tunnel: `curl http://localhost:8080/get`
6. Stop: `docker-compose down`

**Configuration**:
- Edit `docker-compose.yaml` to change ports, volumes, etc.
- View logs in real-time: `docker-compose logs -f [service-name]`

---

## Task: `update-docs`
**Description**: Update project documentation after code changes

**Steps**:
1. Identify affected docs in `/docs/` directory
2. Update relevant files (architecture.md, development.md, etc.)
3. Update main README.md if user-facing changes
4. Run spell check (optional): `aspell check docs/*.md`
5. Verify links still work: check cross-references in docs
6. Commit with message: `git add docs/ README.md && git commit -m "Update docs: describe changes"`

**Key Files**:
- `docs/architecture.md` - System design
- `docs/development.md` - Dev setup and guidelines
- `docs/deployment.md` - Deployment procedures
- `docs/runbook.md` - Operations and troubleshooting

---

## Task: `troubleshoot-connection`
**Description**: Debug connection issues between agent and server

**Steps**:
1. **Check Services Running**:
   - Verify server running: `ps aux | grep fluidity-server`
   - Verify agent running: `ps aux | grep fluidity-agent`

2. **Check Certificates**:
   - List certs: `ls -la certs/`
   - Verify cert validity: `openssl x509 -in certs/server-cert.pem -text -noout`

3. **Check Network Connectivity**:
   - Server listening: `netstat -an | grep 8443`
   - Agent listening: `netstat -an | grep 8080`
   - Test connection: `nc -zv localhost 8443`

4. **Check Logs**:
   - Server logs: `tail -100 logs/server.log`
   - Agent logs: `tail -100 logs/agent.log`
   - Look for: handshake errors, certificate issues, connection refused

5. **Increase Verbosity**:
   - Stop services
   - Set log level to Debug in config
   - Restart and review detailed logs

6. **Check Configuration**:
   - Verify agent points to correct server address
   - Verify ports match (8443 server, 8080 agent)
   - Ensure TLS settings match

---

## Task: `add-new-feature`
**Description**: Add a new feature to Fluidity following project conventions

**Steps**:
1. **Plan and Document**:
   - Create feature branch: `git checkout -b feature/feature-name`
   - Document feature in `/docs/`

2. **Implement**:
   - Add code to `/internal/` in appropriate subdirectory
   - Follow Go conventions and project style
   - Include error handling and logging

3. **Test**:
   - Write unit tests (use table-driven tests)
   - Run tests: `go test -v ./...`
   - Test manually with full stack: `run-full-dev-stack` task

4. **Polish**:
   - Run linter: `golangci-lint run ./...`
   - Check for secrets: `check-security` task
   - Update docs: `update-docs` task

5. **Commit**:
   ```bash
   git add -A
   git commit -m "feat: add new feature description"
   git push origin feature/feature-name
   ```

6. **Create PR** with description of changes

---

**Usage Examples**:
```
@copilot run build-local
@copilot help with test-docker
@copilot: execute run-full-dev-stack
@copilot execute add-go-dependency "github.com/example/package"
```
