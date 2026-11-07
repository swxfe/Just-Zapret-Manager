set shell := ["sh", "-eu", "-c"]

default: bundle

# 1. Проверка синтаксиса, ucode-компиляция и ShellCheck
check:
    sh tools/check.sh

# 2. Модульные, интеграционные тесты и проверка обвязки эмулятора
test: check
    sh tests/run.sh

# 3. Сборка готового dist/just-zapret-manager.sh (после успешных тестов)
bundle: test
    sh tools/bundle.sh

# Release code and all external resources are built separately.
dist: test
    python3 tools/build-assets.py --output dist/jzm-assets.tar.gz
    sh tools/bundle.sh

# 4. Скачать QEMU и сгенерировать чистый образ OpenWrt под Cudy WR3000P
emulator-setup:
    sh tests/e2e/run.sh setup

# 5. Собрать бандл и запустить полный E2E-тест в QEMU
test-e2e: dist
    sh tests/e2e/run.sh
