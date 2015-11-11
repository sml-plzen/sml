MODULE     = sambascripts

SE_COMPILE = checkmodule
SE_PACKAGE = semodule_package
SE_INSTALL = semodule

%.mod: %.te
	$(SE_COMPILE) -m -M -o $@ $<

.PRECIOUS: %.mod
%.pp: %.mod
	$(SE_PACKAGE) -o $@ -m $< $(if $(word 2, $+),-f $(word 2, $+))

.PHONY: install clean

$(MODULE).pp:

install: $(MODULE).pp
	$(SE_INSTALL) -i $<

clean:
	$(RM) *.{mod,pp}
