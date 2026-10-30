.PHONY: app run test cli snapshots release publish clean

app:            ## Build and sign build/Hark.app
	scripts/build-app.sh

run:            ## Build, then launch Hark
	scripts/build-app.sh --open

test:           ## Unit tests (parser, durations, streaming)
	swift test

cli:            ## Build the harkctl test tool
	swift build -c release --product harkctl

snapshots:      ## Render every page and island state to build/snapshots
	swift build -c release --product Hark
	$$(swift build -c release --show-bin-path)/Hark --snapshot build/snapshots

release:        ## Shareable build: make release VERSION=0.3.0 → dist/Hark-0.3.0.dmg + .zip
	scripts/release.sh $(VERSION)

publish:        ## Build, tag, push, and publish on GitHub: make publish VERSION=0.3.0 [NOTES=notes.md]
	scripts/release.sh $(VERSION) --publish $(if $(NOTES),--notes-file $(NOTES))

clean:
	rm -rf .build build
