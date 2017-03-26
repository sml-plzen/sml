# we build CUPS also with relro
%global _hardened_build 1

Summary: OpenPrinting CUPS filters and backends
Name:    cups-filters
Version: 1.13.4
Release: 1.1%{?dist}

# For a breakdown of the licensing, see COPYING file
# GPLv2:   filters: commandto*, imagetoraster, pdftops, rasterto*,
#                   imagetopdf, pstopdf, texttopdf
#         backends: parallel, serial
# GPLv2+:  filters: gstopxl, textonly, texttops, imagetops, foomatic-rip
# GPLv3:   filters: bannertopdf
# GPLv3+:  filters: urftopdf, rastertopdf
# LGPLv2+:   utils: cups-browsed
# MIT:     filters: gstoraster, pdftoijs, pdftoopvp, pdftopdf, pdftoraster
License: GPLv2 and GPLv2+ and GPLv3 and GPLv3+ and LGPLv2+ and MIT

Url:     http://www.linuxfoundation.org/collaborate/workgroups/openprinting/cups-filters
Source0: http://www.openprinting.org/download/cups-filters/cups-filters-%{version}.tar.xz

Patch01: cups-filters-apremotequeueid.patch

Patch10: cups-filters-1.13.4-urf_grayscale_support.patch

Requires: cups-filters-libs%{?_isa} = %{version}-%{release}

# Obsolete cups-php (bug #971741)
Obsoletes: cups-php < 1:1.6.0-1
# Don't Provide it because we don't build the php module
#Provides: cups-php = 1:1.6.0-1

BuildRequires: cups-devel
BuildRequires: pkgconfig
# pdftopdf
BuildRequires: pkgconfig(libqpdf)
# pdftops
BuildRequires: poppler-utils
# pdftoijs, pdftoopvp, pdftoraster, gstoraster
BuildRequires: pkgconfig(poppler)
BuildRequires: poppler-cpp-devel
BuildRequires: libjpeg-devel
BuildRequires: libtiff-devel
BuildRequires: pkgconfig(libpng)
BuildRequires: pkgconfig(zlib)
BuildRequires: pkgconfig(dbus-1)
# libijs
BuildRequires: pkgconfig(ijs)
BuildRequires: pkgconfig(freetype2)
BuildRequires: pkgconfig(fontconfig)
BuildRequires: pkgconfig(lcms2)
# cups-browsed
BuildRequires: avahi-devel
BuildRequires: pkgconfig(avahi-glib)
BuildRequires: pkgconfig(glib-2.0)
BuildRequires: systemd

# Make sure we get postscriptdriver tags.
BuildRequires: python-cups

# Testing font for test scripts.
BuildRequires: dejavu-sans-fonts

# autogen.sh
BuildRequires: autoconf
BuildRequires: automake
BuildRequires: libtool
BuildRequires: mupdf

Requires: cups-filesystem
Requires: poppler-utils

# texttopdf
Requires: liberation-mono-fonts

# pstopdf
Requires: bc grep sed

# cups-browsed
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

# Ghostscript CUPS filters live here since Ghostscript 9.08.
Provides: ghostscript-cups = 9.08
Obsoletes: ghostscript-cups < 9.08

# foomatic-rip's upstream moved from foomatic-filters to cups-filters-1.0.42
Provides: foomatic-filters = 4.0.9-8
Obsoletes: foomatic-filters < 4.0.9-8

%package libs
Summary: OpenPrinting CUPS filters and backends - cupsfilters and fontembed libraries
Group:   System Environment/Libraries
# LGPLv2: libcupsfilters
# MIT:    libfontembed
License: LGPLv2 and MIT

%package devel
Summary: OpenPrinting CUPS filters and backends - development environment
Group:   Development/Libraries
License: LGPLv2 and MIT
Requires: cups-filters-libs%{?_isa} = %{version}-%{release}

%description
Contains backends, filters, and other software that was
once part of the core CUPS distribution but is no longer maintained by
Apple Inc. In addition it contains additional filters developed
independently of Apple, especially filters for the PDF-centric printing
workflow introduced by OpenPrinting.

%description libs
This package provides cupsfilters and fontembed libraries.

%description devel
This is the development package for OpenPrinting CUPS filters and backends.

%prep
%setup -q
%patch01 -p1 -b .apremotequeueid
%patch10 -p1 -b .urf_grayscale

%build
# work-around Rpath
./autogen.sh

# --with-pdftops=hybrid - use Poppler's pdftops instead of Ghostscript for
#                         Brother, Minolta, and Konica Minolta to work around
#                         bugs in the printer's PS interpreters
# --with-rcdir=no - don't install SysV init script
%configure --disable-static \
           --disable-silent-rules \
           --with-pdftops=hybrid \
           --enable-dbus \
           --with-rcdir=no

make %{?_smp_mflags}

%install
make install DESTDIR=%{buildroot}

# Don't ship libtool la files.
rm -f %{buildroot}%{_libdir}/lib*.la

# Not sure what is this good for.
rm -f %{buildroot}%{_bindir}/ttfread

rm -f %{buildroot}%{_pkgdocdir}/INSTALL
mkdir -p %{buildroot}%{_pkgdocdir}/fontembed/
cp -p fontembed/README %{buildroot}%{_pkgdocdir}/fontembed/

# systemd unit file
mkdir -p %{buildroot}%{_unitdir}
install -p -m 644 utils/cups-browsed.service %{buildroot}%{_unitdir}

# LSB3.2 requires /usr/bin/foomatic-rip,
# create it temporarily as a relative symlink
ln -sf %{_cups_serverbin}/filter/foomatic-rip %{buildroot}%{_bindir}/foomatic-rip

# imagetobrf is going to be mapped as /usr/lib/cups/filter/imagetoubrl
ln -sf imagetobrf %{buildroot}%{_cups_serverbin}/filter/imagetoubrl

# textbrftoindex3 is going to be mapped as /usr/lib/cups/filter/textbrftoindexv4
ln -sf textbrftoindexv3 %{buildroot}%{_cups_serverbin}/filter/textbrftoindexv4

# Don't ship urftopdf for now (bug #1002947).
#rm -f %{buildroot}%{_cups_serverbin}/filter/urftopdf
#sed -i '/urftopdf/d' %{buildroot}%{_datadir}/cups/mime/cupsfilters.convs

# Don't ship pdftoopvp for now (bug #1027557).
rm -f %{buildroot}%{_cups_serverbin}/filter/pdftoopvp
rm -f %{buildroot}%{_sysconfdir}/fonts/conf.d/99pdftoopvp.conf


%check
make check

%post
%systemd_post cups-browsed.service

# Initial installation
if [ $1 -eq 1 ] ; then
    IN=%{_sysconfdir}/cups/cupsd.conf
    OUT=%{_sysconfdir}/cups/cups-browsed.conf
    keyword=BrowsePoll

    # We can remove this after few releases, it's just for the introduction of cups-browsed.
    if [ -f "$OUT" ]; then
        echo -e "\n# NOTE: This file is not part of CUPS.\n# You need to enable cups-browsed service\n# and allow ipp-client service in firewall." >> "$OUT"
    fi

    # move BrowsePoll from cupsd.conf to cups-browsed.conf
    if [ -f "$IN" ] && grep -iq ^$keyword "$IN"; then
        if ! grep -iq ^$keyword "$OUT"; then
            (cat >> "$OUT" <<EOF

# Settings automatically moved from cupsd.conf by RPM package:
EOF
            ) || :
            (grep -i ^$keyword "$IN" >> "$OUT") || :
            #systemctl enable cups-browsed.service >/dev/null 2>&1 || :
        fi
        sed -i -e "s,^$keyword,#$keyword directive moved to cups-browsed.conf\n#$keyword,i" "$IN" || :
    fi
fi

%preun
%systemd_preun cups-browsed.service

%postun
%systemd_postun_with_restart cups-browsed.service 

%post libs -p /sbin/ldconfig

%postun libs -p /sbin/ldconfig


%files
%{_pkgdocdir}/README
%{_pkgdocdir}/AUTHORS
%{_pkgdocdir}/NEWS
%config(noreplace) %{_sysconfdir}/cups/cups-browsed.conf
%attr(0755,root,root) %{_cups_serverbin}/filter/*
%attr(0755,root,root) %{_cups_serverbin}/backend/parallel
# Serial backend needs to run as root (bug #212577#c4).
%attr(0700,root,root) %{_cups_serverbin}/backend/serial
%attr(0755,root,root) %{_cups_serverbin}/backend/implicitclass
%attr(0755,root,root) %{_cups_serverbin}/backend/beh
%{_bindir}/foomatic-rip
%{_bindir}/driverless
%{_cups_serverbin}/backend/driverless
%{_cups_serverbin}/driver/driverless
%{_datadir}/cups/banners
%{_datadir}/cups/braille
%{_datadir}/cups/charsets
%{_datadir}/cups/data/*
# this needs to be in the main package because of cupsfilters.drv
%{_datadir}/cups/ppdc/pcl.h
%{_datadir}/cups/ppdc/braille.defs
%{_datadir}/cups/ppdc/fr-braille.po
%{_datadir}/cups/ppdc/imagemagick.defs
%{_datadir}/cups/ppdc/index.defs
%{_datadir}/cups/ppdc/liblouis.defs
%{_datadir}/cups/ppdc/liblouis1.defs
%{_datadir}/cups/ppdc/liblouis2.defs
%{_datadir}/cups/ppdc/liblouis3.defs
%{_datadir}/cups/ppdc/liblouis4.defs
%{_datadir}/cups/ppdc/media-braille.defs
%{_datadir}/cups/drv/cupsfilters.drv
%{_datadir}/cups/drv/generic-brf.drv
%{_datadir}/cups/drv/indexv3.drv
%{_datadir}/cups/drv/indexv4.drv
%{_datadir}/cups/mime/cupsfilters.types
%{_datadir}/cups/mime/cupsfilters.convs
%{_datadir}/cups/mime/cupsfilters-ghostscript.convs
%{_datadir}/cups/mime/cupsfilters-mupdf.convs
%{_datadir}/cups/mime/cupsfilters-poppler.convs
%{_datadir}/cups/mime/braille.convs
%{_datadir}/cups/mime/braille.types
%{_datadir}/ppd/cupsfilters
%{_sbindir}/cups-browsed
%{_unitdir}/cups-browsed.service
%{_mandir}/man8/cups-browsed.8.gz
%{_mandir}/man5/cups-browsed.conf.5.gz
%{_mandir}/man1/foomatic-rip.1.gz
%{_mandir}/man1/driverless.1.gz

%files libs
%dir %{_pkgdocdir}/
%{_pkgdocdir}/COPYING
%{_pkgdocdir}/fontembed/README
%{_libdir}/libcupsfilters.so.*
%{_libdir}/libfontembed.so.*

%files devel
%{_includedir}/cupsfilters
%{_includedir}/fontembed
%{_datadir}/cups/ppdc/escp.h
%{_libdir}/pkgconfig/libcupsfilters.pc
%{_libdir}/pkgconfig/libfontembed.pc
%{_libdir}/libcupsfilters.so
%{_libdir}/libfontembed.so

%changelog
* Mon Mar 20 2017 Michal Růžička <michal.ruza@gmail.com> - 1.13.4-1.1
- Support grayscale colorspace in the urftopdf filter and do ship the filter

* Fri Feb 24 2017 Zdenek Dohnal <zdohnal@redhat.com> - 1.13.4-1
- rebase to 1.13.4
- 1426567 - Added queues are not marked as remote ones

* Fri Feb 10 2017 Fedora Release Engineering <releng@fedoraproject.org> - 1.13.3-4
- Rebuilt for https://fedoraproject.org/wiki/Fedora_26_Mass_Rebuild

* Fri Jan 27 2017 Jonathan Wakely <jwakely@redhat.com> - 1.13.3-3
- Rebuilt for Boost 1.63

* Fri Jan 27 2017 Jonathan Wakely <jwakely@redhat.com> - 1.13.3-2
- Rebuilt for Boost 1.63

* Thu Jan 19 2017 Zdenek Dohnal <zdohnal@redhat.com> - 1.13.3-1
- rebase to 1.13.3

* Mon Jan 02 2017 Zdenek Dohnal <zdohnal@redhat.com> - 1.13.2-1
- rebase to 1.13.2

* Mon Dec 19 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.13.1-1
- rebase to 1.13.1

* Fri Dec 16 2016 David Tardon <dtardon@redhat.com> - 1.13.0-2
- rebuild for poppler 0.50.0

* Mon Dec 12 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.13.0-1
- rebase to 1.13.0

* Fri Dec 02 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.12.0-2
- adding new sources

* Fri Dec 02 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.12.0-1
- rebase to 1.12.0

* Wed Nov 23 2016 David Tardon <dtardon@redhat.com> - 1.11.6-2
- rebuild for poppler 0.49.0

* Fri Nov 11 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.11.6-1
- rebase to 1.11.6

* Mon Oct 31 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.11.5-1
- rebase to 1.11.5

* Fri Oct 21 2016 Marek Kasik <mkasik@redhat.com> - 1.11.4-2
- Rebuild for poppler-0.48.0

* Tue Sep 27 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.11.4-1
- rebase to 1.11.4 

* Tue Sep 20 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.11.3-1
- rebase to 1.11.3

* Tue Aug 30 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.11.2-1
- rebase to 1.11.2, adding cupsfilters-poppler.convs and cupsfilters-mupdf.convs into package

* Wed Aug 03 2016 Jiri Popelka <jpopelka@redhat.com> - 1.10.0-3
- %%{_defaultdocdir}/cups-filters/ -> %%{_pkgdocdir}

* Mon Jul 18 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.10.0-2
- adding new sources cups-filters-1.10.0 

* Mon Jul 18 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.10.0-1
- rebase 1.10.0, include missing ppd.h

* Mon Jul 18 2016 Marek Kasik <mkasik@redhat.com> - 1.9.0-2
- Rebuild for poppler-0.45.0

* Fri Jun 10 2016 Jiri Popelka <jpopelka@redhat.com> - 1.9.0-1
- 1.9.0

* Tue May  3 2016 Marek Kasik <mkasik@redhat.com> - 1.8.3-2
- Rebuild for poppler-0.43.0

* Thu Mar 24 2016 Zdenek Dohnal <zdohnal@redhat.com> - 1.8.3-1
- Update to 1.8.3, adding cupsfilters-ghostscript.convs to %files

* Fri Feb 12 2016 Jiri Popelka <jpopelka@redhat.com> - 1.8.2-1
- 1.8.2

* Wed Feb 03 2016 Fedora Release Engineering <releng@fedoraproject.org> - 1.8.1-3
- Rebuilt for https://fedoraproject.org/wiki/Fedora_24_Mass_Rebuild

* Fri Jan 22 2016 Marek Kasik <mkasik@redhat.com> - 1.8.1-2
- Rebuild for poppler-0.40.0

* Fri Jan 22 2016 Jiri Popelka <jpopelka@redhat.com> - 1.8.1-1
- 1.8.1

* Thu Jan 21 2016 Jiri Popelka <jpopelka@redhat.com> - 1.8.0-1
- 1.8.0

* Tue Jan 19 2016 Jiri Popelka <jpopelka@redhat.com> - 1.7.0-1
- 1.7.0

* Fri Jan 15 2016 Jonathan Wakely <jwakely@redhat.com> - 1.6.0-2
- Rebuilt for Boost 1.60

* Thu Jan 14 2016 Jiri Popelka <jpopelka@redhat.com> - 1.6.0-1
- 1.6.0

* Fri Dec 18 2015 Jiri Popelka <jpopelka@redhat.com> - 1.5.0-1
- 1.5.0

* Tue Dec 15 2015 Jiri Popelka <jpopelka@redhat.com> - 1.4.0-1
- 1.4.0

* Wed Dec 09 2015 Jiri Popelka <jpopelka@redhat.com> - 1.3.0-1
- 1.3.0

* Fri Nov 27 2015 Jiri Popelka <jpopelka@redhat.com> - 1.2.0-1
- 1.2.0

* Wed Nov 11 2015 Peter Robinson <pbrobinson@fedoraproject.org> 1.1.0-2
- Rebuild (qpdf-6)

* Tue Oct 27 2015 Jiri Popelka <jpopelka@redhat.com> - 1.1.0-1
- 1.1.0 (version numbering change: minor version = feature, revision = bugfix)

* Sun Sep 13 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.76-1
- 1.0.76

* Tue Sep 08 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.75-1
- 1.0.75

* Thu Aug 27 2015 Jonathan Wakely <jwakely@redhat.com> - 1.0.74-2
- Rebuilt for Boost 1.59

* Wed Aug 26 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.74-1
- 1.0.74

* Wed Aug 19 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.73-1
- 1.0.73 - new implicitclass backend

* Fri Jul 24 2015 David Tardon <dtardon@redhat.com> - 1.0.71-3
- rebuild for Boost 1.58 to fix deps

* Thu Jul 23 2015 Orion Poplawski <orion@cora.nwra.com> - 1.0.71-2
- Add upstream patch for poppler 0.34 support

* Wed Jul 22 2015 Marek Kasik <mkasik@redhat.com> - 1.0.71-2
- Rebuild (poppler-0.34.0)

* Fri Jul 03 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.71-1
- 1.0.71

* Mon Jun 29 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.70-1
- 1.0.70

* Mon Jun 22 2015 Tim Waugh <twaugh@redhat.com> - 1.0.69-3
- Fixes for glib source handling (bug #1228555).

* Wed Jun 17 2015 Fedora Release Engineering <rel-eng@lists.fedoraproject.org> - 1.0.69-2
- Rebuilt for https://fedoraproject.org/wiki/Fedora_23_Mass_Rebuild

* Thu Jun 11 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.69-1
- 1.0.69

* Fri Jun  5 2015 Marek Kasik <mkasik@redhat.com> - 1.0.68-2
- Rebuild (poppler-0.33.0)

* Tue Apr 14 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.68-1
- 1.0.68

* Wed Mar 11 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.67-1
- 1.0.67

* Mon Mar 02 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.66-1
- 1.0.66

* Mon Feb 16 2015 Jiri Popelka <jpopelka@redhat.com> - 1.0.65-1
- 1.0.65

* Fri Jan 23 2015 Marek Kasik <mkasik@redhat.com> - 1.0.61-3
- Rebuild (poppler-0.30.0)

* Thu Nov 27 2014 Marek Kasik <mkasik@redhat.com> - 1.0.61-2
- Rebuild (poppler-0.28.1)

* Fri Oct 10 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.61-1
- 1.0.61 

* Tue Oct 07 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.60-1
- 1.0.60

* Sun Sep 28 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.59-1
- 1.0.59

* Thu Aug 21 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.58-1
- 1.0.58

* Sat Aug 16 2014 Fedora Release Engineering <rel-eng@lists.fedoraproject.org> - 1.0.55-3
- Rebuilt for https://fedoraproject.org/wiki/Fedora_21_22_Mass_Rebuild

* Fri Aug 15 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.55-2
- Use %%_defaultdocdir instead of %%doc

* Mon Jul 28 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.55-1
- 1.0.55

* Fri Jun 13 2014 Tim Waugh <twaugh@redhat.com> - 1.0.54-4
- Really fix execmem issue (bug #1079534).

* Wed Jun 11 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.54-3
- Remove (F21) pdf-landscape.patch

* Wed Jun 11 2014 Tim Waugh <twaugh@redhat.com> - 1.0.54-2
- Fix build issue (bug #1106101).
- Don't use grep's -P switch in pstopdf as it needs execmem (bug #1079534).
- Return work-around patch for bug #768811.

* Mon Jun 09 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.54-1
- 1.0.54

* Sat Jun 07 2014 Fedora Release Engineering <rel-eng@lists.fedoraproject.org> - 1.0.53-4
- Rebuilt for https://fedoraproject.org/wiki/Fedora_21_Mass_Rebuild

* Tue Jun 03 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.53-3
- Remove BuildRequires pkgconfig(lcms). pkgconfig(lcms2) is enough.

* Tue May 13 2014 Marek Kasik <mkasik@redhat.com> - 1.0.53-2
- Rebuild (poppler-0.26.0)

* Mon Apr 28 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.53-1
- 1.0.53

* Wed Apr 23 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.52-2
- Remove pdftoopvp and urftopdf in %%install instead of not building them.

* Tue Apr 08 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.52-1
- 1.0.52

* Wed Apr 02 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.51-1
- 1.0.51 (#1083327)

* Thu Mar 27 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.50-1
- 1.0.50

* Mon Mar 24 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.49-1
- 1.0.49

* Wed Mar 12 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.48-1
- 1.0.48

* Tue Mar 11 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.47-2
- Don't ship pdftoopvp (#1027557) and urftopdf (#1002947).

* Tue Mar 11 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.47-1
- 1.0.47: CVE-2013-6473 CVE-2013-6476 CVE-2013-6474 CVE-2013-6475 (#1074840)

* Mon Mar 10 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.46-3
- BuildRequires: pkgconfig(foo) instead of foo-devel

* Tue Mar  4 2014 Tim Waugh <twaugh@redhat.com> - 1.0.46-2
- The texttopdf filter requires a TrueType monospaced font
  (bug #1070729).

* Thu Feb 20 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.46-1
- 1.0.46

* Fri Feb 14 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.45-1
- 1.0.45

* Mon Jan 20 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.44-1
- 1.0.44

* Tue Jan 14 2014 Jiri Popelka <jpopelka@redhat.com> - 1.0.43-2
- add /usr/bin/foomatic-rip symlink, due to LSB3.2 (#1052452)

* Fri Dec 20 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.43-1
- 1.0.43: upstream fix for bug #768811 (pdf-landscape)

* Sat Nov 30 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.42-1
- 1.0.42: includes foomatic-rip (obsoletes foomatic-filters package)

* Tue Nov 19 2013 Tim Waugh <twaugh@redhat.com> - 1.0.41-4
- Adjust filter costs so application/vnd.adobe-read-postscript input
  doesn't go via pstotiff (bug #1008166).

* Thu Nov 14 2013 Jaromír Končický <jkoncick@redhat.com> - 1.0.41-3
- Fix memory leaks in cups-browsed (bug #1027317).

* Wed Nov  6 2013 Tim Waugh <twaugh@redhat.com> - 1.0.41-2
- Include dbus so that colord support works (bug #1026928).

* Wed Oct 30 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.41-1
- 1.0.41 - PPD-less printing support

* Mon Oct 21 2013 Tim Waugh <twaugh@redhat.com> - 1.0.40-4
- Fix socket leaks in the BrowsePoll code (bug #1021512).

* Wed Oct 16 2013 Tim Waugh <twaugh@redhat.com> - 1.0.40-3
- Ship the gstoraster MIME conversion rule now we provide that filter
  (bug #1019261).

* Fri Oct 11 2013 Tim Waugh <twaugh@redhat.com> - 1.0.40-2
- Fix PDF landscape printing (bug #768811).

* Fri Oct 11 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.40-1
- 1.0.40
- Use new "hybrid" pdftops renderer.

* Thu Oct 03 2013 Jaromír Končický <jkoncick@redhat.com> - 1.0.39-1
- 1.0.39
- Removed obsolete patches "pdf-landscape" and "browsepoll-notifications"

* Tue Oct  1 2013 Tim Waugh <twaugh@redhat.com> - 1.0.38-4
- Use IPP notifications for BrowsePoll when possible (bug #975241).

* Tue Oct  1 2013 Tim Waugh <twaugh@redhat.com> - 1.0.38-3
- Fixes for some printf-type format mismatches (bug #1014093).

* Tue Sep 17 2013 Tim Waugh <twaugh@redhat.com> - 1.0.38-2
- Fix landscape printing for PDFs (bug #768811).

* Wed Sep 04 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.38-1
- 1.0.38

* Thu Aug 29 2013 Jaromír Končický <jkoncick@redhat.com> - 1.0.37-1
- 1.0.37.

* Tue Aug 27 2013 Jaromír Končický <jkoncick@redhat.com> - 1.0.36-5
- Added build dependency - font required for running tests

* Tue Aug 27 2013 Jaromír Končický <jkoncick@redhat.com> - 1.0.36-4
- Added checking phase (make check)

* Wed Aug 21 2013 Tim Waugh <twaugh@redhat.com> - 1.0.36-3
- Upstream patch to re-work filter costs (bug #998977). No longer need
  text filter costs patch as paps gets used by default now if
  installed.

* Mon Aug 19 2013 Marek Kasik <mkasik@redhat.com> - 1.0.36-2
- Rebuild (poppler-0.24.0)

* Tue Aug 13 2013 Tim Waugh <twaugh@redhat.com> - 1.0.36-1
- 1.0.36.

* Tue Aug 13 2013 Tim Waugh <twaugh@redhat.com> - 1.0.35-7
- Upstream patch to move in filters from ghostscript.

* Tue Jul 30 2013 Tim Waugh <twaugh@redhat.com> - 1.0.35-6
- Set cost for text filters to 200 so that the paps filter gets
  preference for the time being (bug #988909).

* Wed Jul 24 2013 Tim Waugh <twaugh@redhat.com> - 1.0.35-5
- Handle page-label when printing n-up as well.

* Tue Jul 23 2013 Tim Waugh <twaugh@redhat.com> - 1.0.35-4
- Added support for page-label (bug #987515).

* Thu Jul 11 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.35-3
- Rebuild (qpdf-5.0.0)

* Mon Jul 01 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.35-2
- add cups-browsed(8) and cups-browsed.conf(5)
- don't reverse lookup IP address in URI (#975822)

* Wed Jun 26 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.35-1
- 1.0.35

* Mon Jun 24 2013 Marek Kasik <mkasik@redhat.com> - 1.0.34-9
- Rebuild (poppler-0.22.5)

* Wed Jun 19 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-8
- fix the note we add in cups-browsed.conf

* Wed Jun 12 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-7
- Obsolete cups-php (#971741)

* Wed Jun 05 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-6
- one more cups-browsed leak fixed (#959682)

* Wed Jun 05 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-5
- perl is actually not required by pstopdf, because the calling is in dead code

* Mon Jun 03 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-4
- fix resource leaks and other problems found by Coverity & Valgrind (#959682)

* Wed May 15 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-3
- ship ppdc/pcl.h because of cupsfilters.drv

* Tue May 07 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-2
- pstopdf requires bc (#960315)

* Thu Apr 11 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.34-1
- 1.0.34

* Fri Apr 05 2013 Fridolin Pokorny <fpokorny@redhat.com> - 1.0.33-1
- 1.0.33
- removed cups-filters-1.0.32-null-info.patch, accepted by upstream

* Thu Apr 04 2013 Fridolin Pokorny <fpokorny@redhat.com> - 1.0.32-2
- fixed segfault when info is NULL

* Thu Apr 04 2013 Fridolin Pokorny <fpokorny@redhat.com> - 1.0.32-1
- 1.0.32

* Fri Mar 29 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.31-3
- add note to cups-browsed.conf

* Thu Mar 28 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.31-2
- check cupsd.conf existence prior to grepping it (#928816)

* Fri Mar 22 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.31-1
- 1.0.31

* Tue Mar 19 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.30-4
- revert previous change

* Wed Mar 13 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.30-3
- don't ship banners for now (#919489)

* Tue Mar 12 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.30-2
- move BrowsePoll from cupsd.conf to cups-browsed.conf in %%post

* Fri Mar 08 2013 Jiri Popelka <jpopelka@redhat.com> - 1.0.30-1
- 1.0.30: CUPS browsing and broadcasting in cups-browsed

* Wed Feb 13 2013 Fedora Release Engineering <rel-eng@lists.fedoraproject.org> - 1.0.29-4
- Rebuilt for https://fedoraproject.org/wiki/Fedora_19_Mass_Rebuild

* Sat Jan 19 2013 Rex Dieter <rdieter@fedoraproject.org> 1.0.29-3
- backport upstream buildfix for poppler-0.22.x

* Fri Jan 18 2013 Adam Tkac <atkac redhat com> - 1.0.29-2
- rebuild due to "jpeg8-ABI" feature drop

* Thu Jan 03 2013 Jiri Popelka <jpopelka@redhat.com> 1.0.29-1
- 1.0.29

* Wed Jan 02 2013 Jiri Popelka <jpopelka@redhat.com> 1.0.28-1
- 1.0.28: cups-browsed daemon and service

* Thu Nov 29 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.25-1
- 1.0.25

* Fri Sep 07 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.24-1
- 1.0.24

* Wed Aug 22 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.23-1
- 1.0.23: old pdftopdf removed

* Tue Aug 21 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.22-1
- 1.0.22: new pdftopdf (uses qpdf instead of poppler)

* Wed Aug 08 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.20-4
- rebuild

* Thu Aug 02 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.20-3
- commented multiple licensing breakdown (#832130)
- verbose build output

* Thu Aug 02 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.20-2
- BuildRequires: poppler-cpp-devel (to build against poppler-0.20)

* Mon Jul 23 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.20-1
- 1.0.20

* Tue Jul 17 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.19-1
- 1.0.19

* Wed May 30 2012 Jiri Popelka <jpopelka@redhat.com> 1.0.18-1
- initial spec file
