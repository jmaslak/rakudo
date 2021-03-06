# The Kernel class and its methods, underlying $*KERNEL, are a work in progress.
# It is very hard to capture data about a changing universe in a stable API.
# If you find errors for your hardware or OS distribution, please report them
# with the values that you expected and how to get them in your situation.

class Kernel does Systemic {
    has Str $.release;
    has Str $!hardware;
    has Str $!arch;
    has Int $!bits;
    has Bool $!has_uname;

    method !uname($opt) {
        $!has_uname //= "/bin/uname".IO.x || "/usr/bin/uname".IO.x;
        $!has_uname ?? qqx/uname $opt/.chomp !! 'unknown';
    }

    submethod BUILD(:$!auth = "unknown" --> Nil) { }

    method name {
        $!name //= do {
            given $*DISTRO.name {
                when 'mswin32' {
                    'win32'
                }
                when 'browser' {
                    'browser';
                }
                default {
                    lc self!uname('-s');
                }
            }
        }
    }

    method version {
        $!version //= Version.new( do {
            given $*DISTRO.name {
                when 'freebsd' {
                    self!uname('-r'); # -K -U not introduced until 10.0
                }
                when 'macosx' {
                    my $unamev = self!uname('-v');
                    $unamev ~~ m/^Darwin \s+ Kernel \s+ Version \s+ (<[\d\.]>+)/
                      ?? ~$0
                      !! $unamev.chomp;
                }
                default {
                    given $.name {
                        when 'linux' {
                            # somewhat counter-intuitively the '-r' is what
                            # most people think of the kernel version
                            self!uname('-r');
                        }
                        default {
                            self!uname('-v');
                        }
                    }
                }
            }
        } );
    }

    method release {
        $!release //= do {
            given $*DISTRO.name {
                when any <openbsd netbsd dragonfly> { # needs adapting
                    self!uname('-r');
                }
                default {
                    self!uname('-v');
                }
            }
        }
    }

    method hardware {
        $!hardware //= do {
            given $*DISTRO.name {
                default {
                    self!uname('-m');
                }
            }
        }
    }

    method arch {
        $!arch //= do {
            given $*DISTRO.name {
                when 'raspbian' {
                    self!uname('-m');
                }
                default {
                    self!uname('-p');
                }
            }
        }
    }

    method archname {
        self.hardware ~ '-' ~ self.name
    }

    method bits {
        $!bits //= $.hardware ~~ m/_64|w|amd64/ ?? 64 !! 32;  # naive approach
    }

    method hostname {
        nqp::p6box_s(nqp::gethostname)
    }

    has @!signals;  # Signal
#?if jvm
    method signals (Kernel:D:) {
        @!signals //= [2, 9]
    }
#?endif

    has $!signals-setup-lock = Lock.new;
#?if !jvm
    has $!signals-setup = False;
    method signals (Kernel:D:) {
        unless $!signals-setup {
            $!signals-setup-lock.protect: {
                unless $!signals-setup {
                    my @names;
                    if self.name eq 'win32' {
                        # These are the ones libuv emulates on Windows.
                        @names = flat "", <INT BREAK HUP WINCH>;
                    } else {
                        if self.name eq 'openbsd' {
                            # otherwise it uses a shell buildin
                            @names = flat "", qx!/bin/kill -l!.words;
                        }
                        else {
                            @names = flat "", qx/kill -l/.words;
                        }
                        @names.splice(1,1) if @names[1] eq "0";  # Ubuntu fudge
                        @names.=map({.uc}) if $*KERNEL.name eq 'dragonfly';
                    }

                    for Signal.^enum_value_list -> $signal {
                        my $name = substr($signal.key,3);
                        if @names.first( * eq $name, :k ) -> $index {
                            @!signals[$index] = $signal;
                        }
                    }
                    $!signals-setup = True;
                }
            }
        }
        @!signals
    }
#?endif

    has %!signals-by-Str;
    has $!signals-by-Str-setup = False;

    proto method signal (|) {*}
    multi method signal(Kernel:D: Str:D $signal --> Int:D) {
        unless $!signals-by-Str-setup {
            $!signals-setup-lock.protect: {
                unless $!signals-by-Str-setup {
                    nqp::stmts(
                      (my int $els = @.signals.elems),
                      (my int $i = -1),
                      nqp::while(
                        nqp::isgt_i($els, $i = nqp::add_i($i, 1)),
                        ($_ := @!signals.AT-POS($i)).defined
                          && %!signals-by-Str.ASSIGN-KEY(.Str, nqp::decont($i))));
                    $!signals-by-Str-setup = True;
                }
            }
        }
        %!signals-by-Str{$signal} // %!signals-by-Str{"SIG$signal"} // Int;
    }

    multi method signal(Kernel:D: Signal:D \signal --> Int:D) { signal.value }
    multi method signal(Kernel:D: Int:D    \signal --> Int:D) { signal       }

    method cpu-cores() is raw { nqp::cpucores }

    method cpu-usage() is raw {
        my int @rusage;
        nqp::getrusage(@rusage);
        nqp::atpos_i(@rusage, nqp::const::RUSAGE_UTIME_SEC) * 1000000
          + nqp::atpos_i(@rusage, nqp::const::RUSAGE_UTIME_MSEC)
          + nqp::atpos_i(@rusage, nqp::const::RUSAGE_STIME_SEC) * 1000000
          + nqp::atpos_i(@rusage, nqp::const::RUSAGE_STIME_MSEC)
    }

    my $endian := nqp::null;
    method endian(--> Endian:D) {
        nqp::ifnull(
          $endian,
          nqp::bind($endian,nqp::if(
            blob8.new(0,1).read-int16(0) == 1,  # hacky way to find out
            BigEndian,
            LittleEndian
          ))
        )
    }
}

Rakudo::Internals.REGISTER-DYNAMIC: '$*KERNEL', {
    PROCESS::<$KERNEL> := Kernel.new;
}

# vim: ft=perl6 expandtab sw=4
