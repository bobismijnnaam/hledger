# hledger project makefile

# build the normal hledger binary
BUILD=ghc --make hledger.hs -o hledger -O
BUILDFLAGS=-DVTY -DANSI -DHAPPS
build: tag
	$(BUILD) $(BUILDFLAGS)

# force a full rebuild with normal optimisation
rebuild: clean build

# build the fastest binary we can, as hledgeropt
BUILDOPT=ghc --make hledger.hs -o hledgeropt -O2 -fvia-C
buildopt:
	$(BUILDOPT)

# recompile and run tests (or another command) whenever a module changes
# see http://searchpath.org , you may need the patched version from
# http://joyful.com/repos/searchpath
CICMD=test
continuous ci:
	sp --no-exts --no-default-map -o hledger ghc --make hledger.hs $(BUILDFLAGS) --run $(CICMD)

# run code tests
test:
	./hledger.hs test

# build profiling-enabled hledgerp and archive and show a cleaned-up profile
# you may need to rebuild some libs: sudo cabal install --reinstall -p ...
PROFBIN=hledgerp
BUILDPROF=ghc --make hledger.hs -prof -auto-all -o $(PROFBIN)
RUNPROF=./$(PROFBIN) +RTS -p -RTS
PROFCMD=-f sample1000.ledger -s balance
TIME=`date +"%Y%m%d%H%M"`
profile: sampleledgers
	@echo "Profiling $(PROFCMD)"
	$(BUILDPROF)
	$(RUNPROF) $(PROFCMD) #>/dev/null
	tools/simplifyprof.hs $(PROFBIN).prof >simple.prof
	cp simple.prof profs/$(TIME).prof
	echo; cat simple.prof

# run performance benchmarks and save results in profs
# prepend ./ to these if not in $PATH
BENCHEXES=hledger ledger
bench: buildbench sampleledgers
	./bench $(BENCHEXES) | tee profs/`date +%Y%m%d%H%M%S`.bench

# build the benchmarking tool
buildbench:
	ghc --make tools/bench.hs
	rm -f bench; ln -s tools/bench

# generate sample ledgers
sampleledgers:
	ghc -e 'putStr $$ unlines $$ replicate 1000 "!include sample.ledger"' >sample1000.ledger
#	ghc -e 'putStr $$ unlines $$ replicate 10000 "!include sample.ledger"' >sample10000.ledger
#	ghc -e 'putStr $$ unlines $$ replicate 100000 "!include sample.ledger"' >sample10000.ledger

# send unpushed patches to the mail list
send:
	darcs send http://joyful.com/repos/hledger --to=hledger@googlegroups.com --edit-description  

# push patches to the main repo with ssh
push:
	darcs push joyful.com:/repos/hledger

# build a cabal release, tag the repo and upload to hackage
VERSION=`egrep 'version *=' Options.hs | perl -pe 's/.*"(.*?)"/\1/'`
release:
	cabal sdist && darcs tag $(VERSION) && cabal upload dist/hledger-$(VERSION).tar.gz

# update emacs TAGS file
tag:
	rm -f TAGS; hasktags -e *hs Ledger/*hs

clean:
	rm -f {,Ledger/}*{.o,.hi,~} darcs-amend-record*

Clean: clean clean-docs
	rm -f hledger TAGS tags

# docs

DOCS=README NEWS

# rebuild all docs
docs: html pdf api-doc-frames

# rebuild html docs
html:
	for d in $(DOCS); do rst2html $$d >doc/$$d.html; done
	cd doc; ln -f -s README.html index.html

# rebuild pdf docs
pdf:
	for d in $(DOCS); do rst2pdf $$d -o doc/$$d.pdf; done

# rebuild api docs (haddock & hoogle) 
api-docs: api-doc-frames

api-doc-dir:
	mkdir -p api-doc

HSCOLOUR=HsColour -css 
colourised-source hscolour: api-doc-dir
	echo "Generating colourised source" ; \
	for f in *hs Ledger/*hs; do \
		$(HSCOLOUR) -anchor $$f -oapi-doc/`echo "src/"$$f | sed -e's%/%-%g' | sed -e's%\.hs$$%.html%'` ; \
	done ; \
	cp api-doc/src-hledger.html api-doc/src-Main.html ; \
	HsColour -print-css >api-doc/hscolour.css

MAIN=hledger.hs

# nb --ignore-all-exports means these are actually implementation docs
HADDOCK=haddock -B `ghc --print-libdir` --no-warnings --ignore-all-exports
api-doc-with-source: api-doc-dir colourised-source $(MAIN)
	echo "Generating haddock api docs" ; \
	$(HADDOCK) -o api-doc -h --source-module=src-%{MODULE/./-}.html $(filter-out %api-doc-dir colourised-source,$^) ; \
	cp api-doc/index.html api-doc/modules-index.html
#--source-entity=src-%{MODULE/./-}.html#%N 

#generate a hoogle index
hoogleindex: $(MAIN)
	echo "Generating hoogle index" ; \
	mkdir -p hoogle && \
	$(HADDOCK) -o hoogle --hoogle $^ && \
	cd hoogle && \
	hoogle --convert=main.txt --output=default.hoo

#set up the hoogle web interface
#uses a hoogle source tree configured with --datadir=., patched to fix haddock urls/target frame
HOOGLESRC=/usr/local/src/hoogle
HOOGLE=$(HOOGLESRC)/dist/build/hoogle/hoogle
HOOGLEVER=`$(HOOGLE) --version |tail -n 1 | sed -e 's/Version /hoogle-/'`
hoogleweb: hoogleindex
	echo "Configuring hoogle web interface" ; \
	if test -f $(HOOGLE) ; then \
		mkdir -p hoogle && \
		cd hoogle && \
		rm -f $(HOOGLEVER) && \
		ln -s . $(HOOGLEVER) && \
		cp -r $(HOOGLESRC)/src/res/ . && \
		cp -p $(HOOGLE) index.cgi && \
		touch log.txt && chmod 666 log.txt ; \
	else \
		echo "Could not find $(HOOGLE) in the hoogle source tree" ; \
	fi

# munge haddock and hoogle into a rough but useful framed layout
# ensure that the hoogle cgi is built with base target "main"
api-doc-frames: api-doc-with-source hoogleweb
	echo "Converting api docs to frames" ; \
	sed -i -e 's%^></HEAD%><base target="main"></HEAD%' api-doc/modules-index.html ; \
	cp doc/misc/api-doc-frames.html api-doc/index.html ; \
	cp doc/misc/hoogle-small.html hoogle

# build api docs and open them in a web browser, adjust to taste
BROWSER=open
test-docs: api-docs
	$(BROWSER) api-doc/index.html
#	$(BROWSER) doc/README.html

clean-docs:
	rm -rf api-doc hoogle

# misc

show-changes:
	@echo Changes since last release:
	@echo
	@darcs changes --from-tag . | grep '*'

show-unpushed:
	@echo Changes not yet in the main hledger repo:
	@echo
	@darcs push joyful.com:/repos/hledger --dry-run

show-authors:
	@echo Patch authors since last release:
	@echo
	@darcs changes --from-tag . |grep '^\w' |cut -c 31- |sort |uniq

# count lines of code
sloc:
	@echo "test code:"
	@sloccount Tests.hs | grep haskell:
	@echo "non-test code:"
	@sloccount `ls {,Ledger/}*.hs |grep -v Tests.hs` | grep haskell:

