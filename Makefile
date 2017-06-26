VERSION=3.0
PACKAGE=dab
PKGREL=5


SCRIPTS=        				\
	scripts/init.pl				\
	scripts/defenv				\
	scripts/mysql_randompw			\
	scripts/init_urandom			\
	scripts/ssh_gen_host_keys		

GITVERSION:=$(shell cat .git/refs/heads/master)

DEB=${PACKAGE}_${VERSION}-${PKGREL}_all.deb

DESTDIR=
PREFIX=/usr
DATADIR=${PREFIX}/lib/${PACKAGE}
SBINDIR=${PREFIX}/sbin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc/${PACKAGE}
PODDIR=${DOCDIR}/pod

MAN1DIR=${MANDIR}/man1/
PERLDIR=${PREFIX}/share/perl5/

all: ${DEB}

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

.PHONY: install
install: dab dab.1 dab.1.pod DAB.pm devices.tar.gz ${SCRIPTS}
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 dab ${DESTDIR}${SBINDIR}
	install -d ${DESTDIR}${MAN1DIR}
	install -m 0644 dab.1 ${DESTDIR}${MAN1DIR}
	gzip -n -f9 ${DESTDIR}${MAN1DIR}/dab.1
	install -d ${DESTDIR}${PODDIR}
	install -m 0644 dab.1.pod ${DESTDIR}${PODDIR}
	install -D -m 0644 DAB.pm ${DESTDIR}${PERLDIR}/PVE/DAB.pm
	install -d ${DESTDIR}${DATADIR}/scripts
	install -m 0755 ${SCRIPTS} ${DESTDIR}${DATADIR}/scripts
	install -m 0644 devices.tar.gz ${DESTDIR}${DATADIR}

.PHONY: deb
deb: ${DEB}
${DEB}: dab dab.1 DAB.pm control changelog.Debian
	rm -rf debian
	mkdir debian
	make DESTDIR=debian install
	install -d -m 0755 debian/DEBIAN
	sed -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ <control >debian/DEBIAN/control
	install -D -m 0644 copyright debian/${DOCDIR}/copyright
	install -m 0644 changelog.Debian debian/${DOCDIR}
	echo "git clone git://git.proxmox.com/git/dab.git\\ngit checkout ${GITVERSION}" >  debian/${DOCDIR}/SOURCE
	gzip -n -9 debian/${DOCDIR}/changelog.Debian
	fakeroot dpkg-deb --build debian	
	mv debian.deb ${DEB}
	rm -rf debian
	lintian ${DEB}


dab.pdf: dab.1
	groff -man dab.1 |ps2pdf - > dab.pdf

dab.1.pod: dab
	podselect $< > $@.tmp
	mv $@.tmp $@

dab.1: dab.1.pod
	rm -f $@
	pod2man -n $< -s 1 -r ${VERSION} <$< >$@.tmp
	mv $@.tmp $@


.PHONY: clean
clean:
	rm -f ${DEB} dab.1 dab.1.pod dab.pdf *.tmp *~ 

.PHONY: distclean
distclean: clean

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB} | ssh -X repoman@repo.proxmox.com -- upload --product pve --dist stretch


