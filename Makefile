.PHONY: run app install clean

run:
	swift run

app:
	./scripts/bundle.sh

install: app
	rm -rf /Applications/Ma.app
	cp -R build/Ma.app /Applications/

clean:
	rm -rf .build build
