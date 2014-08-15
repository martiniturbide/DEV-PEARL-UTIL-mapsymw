#!perl -w
# mapsymw - mapsym wrapper Watcom map files

# Copyright (c) 2007, 2012 Steven Levine and Associates, Inc.
# All rights reserved.

# This program is free software licensed under the terms of the GNU
# General Public License.  The GPL Software License can be found in
# gnugpl2.txt or at http://www.gnu.org/licenses/licenses.html#GPL

# 2007-07-02 SHL Baseline
# 2007-07-02 SHL Adapt from mapsymb.pl
# 2007-07-28 SHL Relax module name detect
# 2007-07-30 SHL Auto-trim libstdc++ symbols from libc06x maps
# 2007-08-09 SHL Generate dummy symbol for interior segments with no symbols
# 2007-11-08 SHL Drop leading keywords from function definitions
# 2008-12-14 SHL Ensure symbols sorted by value - some apps care
# 2010-05-03 SHL Comments
# 2010-06-14 SHL Avoid missing C++ symbols
# 2012-03-19 SHL Segment names must be uppercase for pmdf

# mapsym requires each segment to have at least 1 symbol
# mapsym requires 32 bit segments to have at least 1 symbol with offset > 65K
# we generate dummy symbols to enforce this
# mapsym does not understand segment 0
# we generate Imp flags to support this

use strict;
use warnings;

# use Package::Subpackage Options;
use POSIX qw(strftime);
use Getopt::Std;
use File::Spec;
use File::Basename;

our $g_version = '0.3';

our $g_cmdname;
our $g_tmpdir;
our @g_mapfiles;			# All map files
our $g_mapfile;				# Current .map file name

&initialize;

our %g_opts;

&scan_args;

print "\n";

foreach $g_mapfile (@g_mapfiles) {
  &mapsym;
}

exit;

# end main

#=== initialize() Intialize globals ===

sub initialize {

  &set_cmd_name;
  &get_tmp_dir;

} # initialize

#=== mapsym() Generate work file, run mapsym on work file ===

sub mapsym {

  # Isolate map file basename
  my $mapid = basename($g_mapfile);
  $mapid =~ s/\.[^.]*$//;		# Strip ext
  verbose_msg("\nProcessing $mapid");

  fatal("$g_mapfile does not exist.") if ! -f $g_mapfile;

  open MAPFILE, $g_mapfile or die "open $g_mapfile $!";

  my $g_wrkfile = File::Spec->catfile($g_tmpdir, "$mapid.map");
  unlink $g_wrkfile || die "unlink $g_wrkfile $!" if -f $g_wrkfile;
  open WRKFILE, ">$g_wrkfile" or die "open $g_wrkfile $!";

  my $modname;
  my $state = '';
  my $segcnt = 0;
  my $symcnt = 0;
  my $is32bit;
  my %segsinfo;
  my %syms;
  my $segnum;
  my $offset;
  my $segaddr;

  my $segfmt;
  my $symfmt;

  while (<MAPFILE>) {

    chomp;			# EOL

    if (/Executable Image: (\S+)\.\w+$/) {
      $modname = $1;
      print WRKFILE "Generated by $g_cmdname from $g_mapfile on ",
		    strftime('%A, %B %d, %Y at %I:%M %p', localtime), "\n\n";
      print WRKFILE " $modname\n";
    }

    $state = 'segments'
      if /Segment                Class          Group          Address         Size/;

    $state = 'addresses' if /Address        Symbol/;

    # Skip don't cares
    next if /^=/;
    next if /^ /;
    next if /^$/;

    if ($state eq 'segments') {
      # In
      # Segment                Class          Group          Address         Size
      # _TEXT16                CODE           AUTO           0001:00000000   00000068
      # Out
      # 0        1         2         3         4         5         6
      # 123456789012345678901234567890123456789012345678901234567890
      #  Start         Length     Name                   Class
      #  0001:00000000 000000030H _MSGSEG32              CODE 32-bit

      if (/^(\w+)\s+(\w+)\s+\w+\s+([[:xdigit:]]+):([[:xdigit:]]+)\s+([[:xdigit:]]+)$/) {
	my $segname = $1;
	my $class = $2;
	$segnum = $3;			# Has leading 0's
	$offset = $4;
	my $seglen = $5;

	$segaddr = "$segnum:$offset";

	if (!$segcnt) {
	  # First segment - determine address size (16/32 bit)
	  $is32bit = length($offset) == 8;
	  # Output title
	  print WRKFILE "\n";
	  if ($is32bit) {
	    print WRKFILE " Start         Length     Name                   Class\n";
	    $segfmt = " %13s 0%8sH %-22s %s\n";
	    $symfmt = " %13s  %3s  %s\n";
	  } else {
	    print WRKFILE " Start     Length Name                   Class\n";
	    $segfmt = " %9s 0%4sH %-22s %s\n";
	    $symfmt = " %9s  %3s  %s\n";
	  }
	}

	$seglen = substr($5, -4) if !$is32bit;

	printf WRKFILE $segfmt, $segaddr, $seglen, $segname, $class;
	$segcnt++;
      }
    } # if segments

    if ($state eq 'addresses') {
      # In
      #	Address        Symbol
      # 0002:0004ae46+ ArcTextProc
      # 0002:0d11+     void near IoctlAudioCapability( __2bd9g9REQPACKET far *, short unsigned )
      # Out
      # 0        1         2         3         4         5         6
      # 123456789012345678901234567890123456789012345678901234567890
      #   Address         Publics by Value
      #  0000:00000000  Imp  WinEmptyClipbrd      (PMWIN.733)
      #  0002:0001ED40       __towlower_dummy
      if (/^([[:xdigit:]]+):([[:xdigit:]]+)[+*]?\s+(.+)$/) {
	$segnum = $1;
	$offset = $2;
	my $sym = $3;

	my $seginfo;
	if (defined($segsinfo{$1})) {
	  $seginfo = $segsinfo{$1};
	}
	else {
	  $seginfo = {max_offset => 0,
		      symcnt => 0};
	}

	my $n = hex $offset;
	# Remember max symbol offset
	$seginfo->{max_offset} = $n if $n > $seginfo->{max_offset};
	$seginfo->{symcnt}++;

	$segsinfo{$1} = $seginfo;

	$segaddr = "$segnum:$offset";

	# Convert C++ symbols to something mapsym will accept
	# warn "$sym\n";

	$_ = $sym;

	# s/\bIdle\b/    /;	# Drop Idle keyword - obsolete done later
	s/\(.*\).*$//;		# Drop (...) tails

	s/::~/__x/;		# Replace ::~ with __x
	s/::/__/;		# Replace :: with __

	s/[<,]/_/g;		# Replace < and , with _
	s/[>]//g;		# Replace > with nothing
	s/[\[\]]//g;		# Replace [] with nothing
	# s/_*$//;		# Drop trailing _
	# s/\W+\w//;		# Drop leading keywords (including Idle)
	s/\b.*\b\s+//g;		# Drop leading keywords (including Idle)

	# Drop leading and trailing _ to match source code

	s/^_//;			# Drop leading _ (cdecl)
	s/_$//;			# Drop trailing _ (watcall)

	# warn "$_\n";

	# Prune some libc symbols to avoid mapsym overflows
	if ($mapid =~ /libc06/) {
	  # 0001:000b73e0  __ZNSt7codecvtIcc11__mbstate_tEC2Ej
	  # next if / [0-9A-F]{4}:[0-9A-F]{8} {7}S/;
	  next if /\b__Z/;		# Prune libstdc++
	}

	if (!$symcnt) {
	  # First symbol - output title
	  print WRKFILE "\n";
	  if ($is32bit) {
	    print WRKFILE "  Address         Publics by Value\n";
	  } else {
	    print WRKFILE "  Address     Publics by Value\n";
	  }
	}

	$syms{$segaddr} = $_;

	$symcnt++;
      }
    } # if addresses

  } # while lines

  close MAPFILE;

  # Sort segments

  my @keys = sort keys %segsinfo;
  if (@keys) {
    my $maxseg = pop @keys;
    @keys = '0000'..$maxseg;
  }

  # Generate dummy symbols for 32-bit segments smaller than 64KB

  foreach $segnum (@keys) {
    if ($segnum != 0) {
      my $seginfo;
      if (defined($segsinfo{$segnum})) {
	$seginfo = $segsinfo{$segnum};
      }
      else {
	$seginfo = {max_offset => 0,
		    symcnt => 0};
      }
      if ($seginfo->{symcnt} == 0) {
	warn "Segment $segnum has no symbols - generating dummy symbol\n";
	$_ = "SEG${segnum}_dummy";
	if ($is32bit) {
	  $segaddr = "$segnum:00010000";
	} else {
	  $segaddr = "$segnum:0000";
	}
	$syms{$segaddr} = $_;
	$symcnt++;
      } elsif ($is32bit && $seginfo->{max_offset} < 0x10000) {
	warn "32 bit segment $segnum is smaller than 64K - generating dummy symbol\n";
	$_ = "SEG${segnum}_dummy";
	$segaddr = "$segnum:00010000";
	$syms{$segaddr} = $_;
	$symcnt++;
      }
    }
  } # foreach

  # Generate symbols by value listing

  my $lastsym = '';
  my $seq = 0;
  @keys = sort keys %syms;
  foreach $segaddr (@keys) {
    my $sym = $syms{$segaddr};
    my $imp = substr($segaddr, 0, 4) eq '0000' ? 'Imp' : '';
    if ($sym ne $lastsym) {
      $lastsym = $sym;
      $seq = 0;
    } else {
      $seq++;
      $sym = "${sym}_$seq";
    }
    printf WRKFILE $symfmt, $segaddr, $imp, $sym;
  }

  close WRKFILE;

  die "Can not locate module name.  $g_mapfile is probably not a Watcom map file\n" if !defined($modname);

  my $symfile = "$mapid.sym";
  unlink $symfile || die "unlink $symfile $!" if -f $symfile;

  warn "Processed $segcnt segments and $symcnt symbols for $modname\n";

  system("mapsym $g_wrkfile");

} # mapsym

#=== scan_args(cmdLine) Scan command line ===

sub scan_args {

  getopts('dhtvV', \%g_opts) || &usage;

  &help if $g_opts{h};

  if ($g_opts{V}) {
    print "$g_cmdname v$g_version";
    exit;
  }

  my $arg;

  for $arg (@ARGV) {
    my @maps = glob($arg);
    usage("File $arg not found") if @maps == 0;
    push @g_mapfiles, @maps;
  } # for arg

} # scan_args

#=== help() Display scan_args usage help exit routine ===

sub help {

  print <<EOD;
Generate .sym file for Watcom map files.
Generates temporary map file reformatted for mapsym and
invokes mapsym to process this map file.

Usage: $g_cmdname [-d] [-h] [-v] [-V] mapfile...
 -d      Display debug messages
 -h      Display this message
 -v      Display progress messages
 -V      Display version

 mapfile List of map files to process
EOD

  exit 255;

} # help

#=== usage(message) Report Scanargs usage error exit routine ===

sub usage {

  my $msg = shift;
  print "\n$msg\n" if $msg;
print <<EOD;

Usage: $g_cmdname [-d] [-h] [-v] [-V] mapfile...
EOD
  exit 255;

} # usage

#==========================================================================
#=== SkelFunc standards - Delete unused - Move modified above this mark ===
#==========================================================================

#=== verbose_msg(message) Display message if verbose ===

sub verbose_msg {
  if ($g_opts{v}) {
    my $msg = shift;
    if (defined $msg) {
      print STDOUT "$msg\n";
    } else {
      print STDOUT "\n";
    }
  }
} # verbose_msg

#==========================================================================
#=== SkelPerl standards - Delete unused - Move modified above this mark ===
#==========================================================================

#=== fatal(message) Report fatal error and exit ===

sub fatal {
  my $msg = shift;
  print "\n";
  print STDERR "$g_cmdname: $msg\a\n";
  exit 254;

} # fatal

#=== set_cmd_name() Set $g_cmdname to script name less path and extension ===

sub set_cmd_name {
  $g_cmdname = $0;
  $g_cmdname = basename($g_cmdname);
  $g_cmdname =~ s/\.[^.]*$//;		# Chop ext

} # set_cmd_name

#=== get_tmp_dir() Get TMP dir name with trailing backslash, set Gbl. ===

sub get_tmp_dir {

  $g_tmpdir = File::Spec->tmpdir();
  die "Need to have TMP or TMPDIR or TEMP defined" unless $g_tmpdir;

} # get_tmp_dir

# The end
