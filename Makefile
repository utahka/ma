.PHONY: run icon app install clean

run:
	swift run

icon:
	./scripts/icon.sh

app:
	./scripts/bundle.sh

install: app
	rm -rf /Applications/Awai.app
	cp -R build/Awai.app /Applications/

clean:
	rm -rf .build build
