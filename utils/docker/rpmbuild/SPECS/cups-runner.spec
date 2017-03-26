Summary: A Docker container runner for the CUPS daemon.
Name:    cups-runner
Version: 1.0.0
Release: 1%{?dist}

License: GPLv3+

Source: run-cupsd-%{version}.sh

Requires: cups
Requires: portreserve

%description
Provides a simple wrapper for the CUPS daemon suitable for a Docker
contianer environment.

%install
install -d %{buildroot}%{_sbindir}
install -p -m 755 %{SOURCE0} %{buildroot}%{_sbindir}/run-cupsd

%files
%defattr(-, root, root, -)
%{_sbindir}/*

%changelog
* Mon Mar 27 2017 Michal Růžička <michal.ruza@gmail.com> - 1.0.0-1
- Initial packaging
