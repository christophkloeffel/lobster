SYSTEM_PYTHONPATH:=$(PYTHONPATH)
export LOBSTER_ROOT=$(PWD)
export PYTHONPATH=$(LOBSTER_ROOT)
export PATH:=$(LOBSTER_ROOT):$(PATH)

ASSETS=$(wildcard assets/*.svg)
TOOL_FOLDERS := $(shell find ./lobster/tools -mindepth 1 -maxdepth 2 -type d | grep -v -E '^./lobster/tools/core$$|__pycache__|parser' | sed 's|^./lobster/tools/||; s|/|-|g')

.PHONY: packages docs

lobster/html/assets.py: $(ASSETS) util/mkassets.py
	util/mkassets.py lobster/html/assets.py $(ASSETS)

lint: style
	@PYTHONPATH=$(SYSTEM_PYTHONPATH) \
	python3 -m pylint --rcfile=pylint3.cfg \
		--reports=no \
		--ignore=assets.py \
		lobster util

lint-system-tests: style
	@PYTHONPATH=$(SYSTEM_PYTHONPATH) \
	python3 -m pylint --rcfile=tests-system/pylint3.cfg \
		--reports=no \
		tests-system/systemtestcasebase.py \
		tests-system/asserter.py \
		tests-system/lobster-json

trlc:
	trlc lobster --error-on-warnings --verify

style:
	@python3 -m pycodestyle lobster tests-system \
		--exclude=assets.py

packages:
	git clean -xdf
	make lobster/html/assets.py
	make -C packages/lobster-core
	make -C packages/lobster-tool-trlc
	make -C packages/lobster-tool-codebeamer
	make -C packages/lobster-tool-cpp
	make -C packages/lobster-tool-cpptest
	make -C packages/lobster-tool-gtest
	make -C packages/lobster-tool-json
	make -C packages/lobster-tool-python
	make -C packages/lobster-metapackage
	make -C packages/lobster-monolithic
	PYTHONPATH= \
		pip3 install --prefix test_install \
		packages/*/dist/*.whl
	PYTHONPATH= \
		pip3 install --prefix test_install_monolithic \
		packages/lobster-monolithic/meta_dist/*.whl
	diff -Naur test_install/lib/python*/site-packages/lobster test_install_monolithic/lib/python*/site-packages/lobster -x "*.pyc"
	diff -Naur test_install/bin test_install_monolithic/bin

clang-tidy:
	cd .. && \
	git clone https://github.com/bmw-software-engineering/llvm-project && \
	cd llvm-project && \
	cmake -S llvm -B build -G Ninja -DLLVM_ENABLE_PROJECTS='clang;clang-tools-extra' -DCMAKE_BUILD_TYPE=Release && \
	cmake --build build --target clang-tidy

selenium-tests:
	@make lobster/html/assets.py
	@echo "Running Selenium Tests..."
	(cd tests-UI; make)

integration-tests: packages
	(cd tests-integration/projects/basic; make)
	(cd tests-integration/projects/filter; make)
	rm -f MODULE.bazel MODULE.bazel.lock

system-tests:
	mkdir -p docs
	python -m unittest discover -s tests-system -v -t .
	make -B -C tests-system TOOL=lobster-report
	make -B -C tests-system TOOL=lobster-trlc
	make -B -C tests-system TOOL=lobster-python
	make -B -C tests-system TOOL=lobster-online-report
	make -B -C tests-system TOOL=lobster-html-report

unit-tests:
	coverage run -p \
			--branch --rcfile=coverage.cfg \
			--data-file .coverage \
			--source=lobster \
			-m unittest discover -s tests-unit -v

upload-main: packages
	python3 -m twine upload --repository pypi packages/*/dist/*
	python3 -m twine upload --repository pypi packages/*/meta_dist/*

remove-dev:
	python3 -m util.release

github-release:
	git push
	python3 -m util.github_release

bump:
	python3 -m util.bump_version_post_release

full-release:
	make remove-dev
	git push
	make github-release
	make bump
	git push

coverage:
	coverage combine -q
	coverage html --rcfile=coverage.cfg
	coverage report --rcfile=coverage.cfg --fail-under=55

test: clean-coverage system-tests unit-tests
	make coverage
	util/check_local_modifications.sh

test-all: integration-tests system-tests unit-tests
	make coverage
	util/check_local_modifications.sh

docs:
	rm -rf docs
	mkdir -p docs
	@-make tracing
	@-make tracing-stf

tracing:
	@mkdir -p docs
	@make lobster/html/assets.py
	@for tool in $(TOOL_FOLDERS); do \
		make tracing-tools-$$tool; \
	done

tracing-tools-%: tracing-%
	@echo "Finished processing tool: $*"

tracing-%: report.lobster-%
	$(eval TOOL_PATH := $(subst -,_,$*))
	lobster-html-report report.lobster --out=docs/tracing-$(TOOL_PATH).html
	lobster-ci-report report.lobster

report.lobster-%: lobster/tools/lobster.conf \
				  code.lobster-% \
				  unit-tests.lobster-% \
				  system_requirements.lobster-% \
				  software_requirements.lobster-% \
				  system-tests.lobster-%
	lobster-report \
		--lobster-config=lobster/tools/lobster.conf \
		--out=report.lobster
	lobster-online-report report.lobster

system_requirements.lobster-%: lobster/tools/requirements.rsl
	$(eval TOOL_PATH := $(subst -,/,$*))   
	lobster-trlc lobster/tools/$(TOOL_PATH) lobster/tools/requirements.rsl \
	--config-file=lobster/tools/lobster-trlc-system.conf \
	--out system_requirements.lobster

software_requirements.lobster-%: lobster/tools/requirements.rsl
	$(eval TOOL_PATH := $(subst -,/,$*))   
	lobster-trlc lobster/tools/$(TOOL_PATH) lobster/tools/requirements.rsl \
	--config-file=lobster/tools/lobster-trlc-software.conf \
	--out software_requirements.lobster

code.lobster-%:
	$(eval TOOL_PATH := $(subst -,/,$*))
	lobster-python --out code.lobster lobster/tools/$(TOOL_PATH)

unit-tests.lobster-%:
	$(eval TOOL_NAME := $(subst _,-,$(notdir $(TOOL_PATH))))
	lobster-python --activity --out unit-tests.lobster tests-unit/lobster-$(TOOL_NAME)

system-tests.lobster-%:
	lobster-python --activity --out=system-tests.lobster tests-system/lobster-$*

# STF is short for System Test Framework
STF_TRLC_FILES := $(wildcard tests-system/*.trlc)
STF_PYTHON_FILES := $(filter-out tests-system/test_%.py tests-system/run_tool_tests.py, $(wildcard tests-system/*.py))

# This target is used to generate the LOBSTER report for the requirements of the system test framework itself.
tracing-stf: $(STF_TRLC_FILES)
	lobster-trlc tests-system lobster/tools/requirements.rsl --config-file=lobster/tools/lobster-trlc-system.conf --out=stf_system_requirements.lobster
	lobster-trlc tests-system lobster/tools/requirements.rsl --config-file=lobster/tools/lobster-trlc-software.conf --out=stf_software_requirements.lobster
	lobster-python --out=stf_code.lobster --only-tagged-functions $(STF_PYTHON_FILES)
	lobster-report --lobster-config=tests-system/stf-lobster.conf --out=stf_report.lobster
	lobster-online-report stf_report.lobster
	lobster-html-report stf_report.lobster --out=docs/tracing-stf.html
	@echo "Deleting STF *.lobster files..."
	rm -f stf_system_requirements.lobster stf_software_requirements.lobster stf_code.lobster stf_report.lobster

clean-coverage:
	@rm -rf htmlcov
	@find . -name '.coverage*' -type f -delete
	@find . -name '*.pyc' -type f -delete
	@echo "All .coverage, .coverage.* and *.pyc files deleted."
