include /usr/share/dpkg/pkg-info.mk

PACKAGE=dab

BUILDDIR ?= ${PACKAGE}-${DEB_VERSION_UPSTREAM}

SCRIPTS=        				\
	scripts/init.pl				\
	scripts/defenv				\
	scripts/mysql_randompw			\
	scripts/init_urandom			\
	scripts/ssh_gen_host_keys		

GITVERSION:=$(shell git rev-parse HEAD)

DEB=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}_all.deb
DSC=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}.dsc

DESTDIR=
PREFIX=/usr
DATADIR=${DESTDIR}/${PREFIX}/lib/${PACKAGE}
SBINDIR=${DESTDIR}/${PREFIX}/sbin
MANDIR=${DESTDIR}/${PREFIX}/share/man
DOCDIR=${DESTDIR}/${PREFIX}/share/doc/${PACKAGE}

PODDIR=${DOCDIR}/pod
MAN1DIR=${MANDIR}/man1/
PERLDIR=${DESTDIR}/${PREFIX}/share/perl5/

# avoid build loops, as we have nor real folder structure here
all:

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

.PHONY: install
install: dab dab.1 dab.1.pod DAB.pm devices.tar.gz ${SCRIPTS}
	install -d ${SBINDIR}
	install -m 0755 dab ${SBINDIR}
	install -d ${MAN1DIR}
	install -m 0644 dab.1 ${MAN1DIR}
	gzip -n -f9 ${MAN1DIR}/dab.1
	install -d ${PODDIR}
	install -m 0644 dab.1.pod ${PODDIR}
	install -D -m 0644 DAB.pm ${PERLDIR}/PVE/DAB.pm
	install -d ${DATADIR}/scripts
	install -m 0755 ${SCRIPTS} ${DATADIR}/scripts
	install -m 0644 devices.tar.gz ${DATADIR}

${BUILDDIR}:
	rm -rf ${BUILDDIR}
	rsync -a * ${BUILDDIR}
	echo "git clone git://git.proxmox.com/git/dab.git\\ngit checkout ${GITVERSION}" >  ${BUILDDIR}/debian/SOURCE

.PHONY: deb
deb: ${DEB}
${DEB}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

.PHONY: dsc
dsc: ${DSC}
${DSC}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -S -us -uc -d -nc
	lintian ${DSC}


dab.pdf: dab.1
	groff -man dab.1 |ps2pdf - > dab.pdf

dab.1.pod: dab
	podselect $< > $@.tmp
	mv $@.tmp $@

dab.1: dab.1.pod
	rm -f $@
	pod2man -n $< -s 1 -r ${DEB_VERSION_UPSTREAM} <$< >$@.tmp
	mv $@.tmp $@


.PHONY: clean
clean:
	rm -rf ${PACKAGE}-*/ *.deb *.dsc dab_*.tar.gz dab.1 dab.1.pod dab.pdf *.tmp *.changes *.buildinfo *~

.PHONY: distclean
distclean: clean

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB} | ssh -X repoman@repo.proxmox.com -- upload --product pve --dist buster
