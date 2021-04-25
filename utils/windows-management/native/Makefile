CXX = x86_64-w64-mingw32-g++

CXXFLAGS = -O3 -mwin32 -mconsole
# Unicode
CXXFLAGS += -municode -D_UNICODE

BINEXT := .exe

ALL := keyexport

TARGETS = $(addsuffix $(BINEXT), $(ALL))

%.exe: %.c
	$(LINK.cc) $^ $(LOADLIBES) $(LDLIBS) -o $@


all: $(TARGETS)

$(TARGETS): .EXTRA_PREREQS = $(MAKEFILE_LIST)

keyexport$(BINEXT): CXXFLAGS += -Iinclude

clean:
	$(RM) $(TARGETS)
