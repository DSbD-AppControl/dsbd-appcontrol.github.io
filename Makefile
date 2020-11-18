# ----------------------------------------------------------------- [ Makefile ]
# Module    : Makefile
# Copyright : (c) Jan de Muijnck-Hughes
# License   : see LICENSE
# ---------------------------------------------------------------------- [ EOH ]

REPO := git@github.com:DSbD-AppControl/dsbd-appcontrol.github.io.git

SITE := stack exec site

.PHONY: build serve deploy clean setup watch

watch: build
	${SITE} watch

setup:
	stack setup

build: setup
	stack build
	${SITE} build

clean:
	${SITE} clean

serve: build
	${SITE} server

deploy: build
	rm -rf _site/.git
	(cd _site; git init && git add .)
#	(cd _site; git config user.email "")
#	(cd _site; git config user.name None)
	(cd _site; git commit -m "Site Generated on `date`")
	(cd _site; git remote add origin ${REPO})
	(cd _site; git branch -M published)
	(cd _site; git push -f origin published)
# ---------------------------------------------------------------------- [ EOF ]
