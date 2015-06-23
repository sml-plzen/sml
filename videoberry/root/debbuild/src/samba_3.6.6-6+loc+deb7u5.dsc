Format: 3.0 (quilt)
Source: samba
Binary: samba, samba-common-bin, samba-common, samba-tools, smbclient, swat, samba-doc, samba-doc-pdf, libpam-smbpass, libsmbclient, libsmbclient-dev, winbind, libpam-winbind, libnss-winbind, samba-dbg, libwbclient0, libwbclient-dev
Architecture: any all
Version: 2:3.6.6-6+loc+deb7u5
Maintainer: Debian Samba Maintainers <pkg-samba-maint@lists.alioth.debian.org>
Uploaders: Steve Langasek <vorlon@debian.org>, Christian Perrier <bubulle@debian.org>, Noèl Köthe <noel@debian.org>, Jelmer Vernooij <jelmer@debian.org>
Homepage: http://www.samba.org
Standards-Version: 3.9.3
Vcs-Browser: http://svn.debian.org/wsvn/pkg-samba/trunk/samba/
Vcs-Svn: svn://svn.debian.org/svn/pkg-samba/trunk/samba
Build-Depends: debhelper (>= 9~), libpam0g-dev, libreadline-dev, libcups2-dev, libacl1-dev [linux-any], libkrb5-dev (>= 1.10+dfsg~), libldap2-dev, po-debconf, libpopt-dev, uuid-dev, libtalloc-dev (>= 2.0.1-1~bpo50+1), libtdb-dev (>= 1.2.6~), libcap-dev [linux-any], libkeyutils-dev [linux-any], libctdb-dev (>= 1.10+git20110412), pkg-config
Build-Conflicts: libfam-dev, python-ldb, python-ldb-dev
Package-List: 
 libnss-winbind deb net optional
 libpam-smbpass deb admin extra
 libpam-winbind deb net optional
 libsmbclient deb libs optional
 libsmbclient-dev deb libdevel extra
 libwbclient-dev deb libdevel optional
 libwbclient0 deb libs optional
 samba deb net optional
 samba-common deb net optional
 samba-common-bin deb net optional
 samba-dbg deb debug extra
 samba-doc deb doc optional
 samba-doc-pdf deb doc optional
 samba-tools deb net optional
 smbclient deb net optional
 swat deb net optional
 winbind deb net optional
Checksums-Sha1: 
 450371e613d867a2d42555998cd3e83a47014123 29464478 samba_3.6.6.orig.tar.bz2
 b51b0ec98657245a5d8a96461fa8a402f6b7d2ba 419929 samba_3.6.6-6+loc+deb7u5.debian.tar.gz
Checksums-Sha256: 
 1141eb5f173534db8f8d7dd1aa8fed53404d719e4a65c610f3ef62fdcad783e6 29464478 samba_3.6.6.orig.tar.bz2
 5821bd4b85ea0446fcf4204be5e40529ec185993be9b3d5e6d8089d9916a1dc0 419929 samba_3.6.6-6+loc+deb7u5.debian.tar.gz
Files: 
 46b07ed027657917413f6bfc7234db38 29464478 samba_3.6.6.orig.tar.bz2
 c4d8e4fedcc2541d87b3a1c7e8af93fd 419929 samba_3.6.6-6+loc+deb7u5.debian.tar.gz
