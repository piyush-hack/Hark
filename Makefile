.PHONY: app run test cli snapshots clean

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

clean:
	rm -rf .build build
