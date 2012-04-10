VERSION=1.1
PACKAGE=dab
PKGREL=15


SCRIPTS=        				\
	scripts/init.pl				\
	scripts/defenv				\
	scripts/mysql_randompw			\
	scripts/init_urandom			\
	scripts/ssh_gen_host_keys		

DEB=${PACKAGE}_${VERSION}-${PKGREL}_all.deb

DESTDIR=
PREFIX=/usr
DATADIR=${PREFIX}/lib/${PACKAGE}
SBINDIR=${PREFIX}/sbin
MANDIR=${PREFIX}/share/man
DOCDIR=${PREFIX}/share/doc/${PACKAGE}
MAN1DIR=${MANDIR}/man1/
PERLDIR=${PREFIX}/share/perl5/

all: ${DEB}

.PHONY: install
install: dab dab.1 DAB.pm devices.tar.gz ${SCRIPTS}
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 dab ${DESTDIR}${SBINDIR}
	install -d ${DESTDIR}${MAN1DIR}
	install -m 0644 dab.1 ${DESTDIR}${MAN1DIR}
	gzip -f9 ${DESTDIR}${MAN1DIR}/dab.1
	install -D -m 0644 DAB.pm ${DESTDIR}${PERLDIR}/PVE/DAB.pm
	install -d ${DESTDIR}${DATADIR}/scripts
	install -m 0755 ${SCRIPTS} ${DESTDIR}${DATADIR}/scripts
	install -m 0644 devices.tar.gz ${DESTDIR}${DATADIR}

.PHONY: deb
deb ${DEB}: dab dab.1 DAB.pm control changelog.Debian
	rm -rf debian
	mkdir debian
	make DESTDIR=debian install
	install -d -m 0755 debian/DEBIAN
	sed -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ <control >debian/DEBIAN/control
	install -D -m 0644 copyright debian/${DOCDIR}/copyright
	install -m 0644 changelog.Debian debian/${DOCDIR}
	gzip -9 debian/${DOCDIR}/changelog.Debian
	dpkg-deb --build debian	
	mv debian.deb ${DEB}
	rm -rf debian
	lintian ${DEB}


dab.pdf: dab.1
	groff -man dab.1 |ps2pdf - > dab.pdf

dab.1: dab
	rm -f dab.1
	pod2man -n $< -s 1 -r ${VERSION} <$< >$@


.PHONY: clean
clean:
	rm -f ${DEB} dab.1 dab.pdf *~ 

