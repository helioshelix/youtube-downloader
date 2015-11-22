#!/usr/bin/perl -w
use strict;
use warnings;
use Cwd ();
use File::Basename ();
use File::Path ('make_path');
use Getopt::Long ('GetOptionsFromString', ':config', 'no_auto_abbrev');
use Thread::Pool::Simple;
use threads::shared;
use Time::HiRes ('usleep');
use WWW::YouTube::Download;
use HTML::Entities ();
#use Data::Dumper;
#$Data::Dumper::Sortkeys++;
#$Data::Dumper::Terse++;
#$Data::Dumper::Quotekeys--;
$|=1;

sub cd(;$);
sub get_cwd;
sub create_dir($);
sub clean_encode($);
sub extract_from_array(@);
sub extract_from_files(@);
sub read_file($);
sub parse_url($);
sub enum_titles;
sub parse_playlist($);
sub download_playlist($);

unless(@ARGV){
	&show_help;
}

cd;
my $main_dir = get_cwd;
my $file_dir = $main_dir . 'downloads/';

my $user_agent = 'Mozilla/5.0 (Windows NT 6.1; WOW64; rv:21.0) Gecko/20100101 Firefox/21.0';
my $time_out = 10;
#my $time_out = 10;

my %options = 
(
	download_playlist 	=> undef,
	help 				=> 0,
	files				=> [],
	urls				=> [],
	overwrite			=> 0,
	threads				=> 4,
	useragent			=> undef,
	timeout				=> undef,
	proxy				=> undef,
	dont_delete			=> 0,
	parse_playlist 		=> undef,
	ids_only			=> 0,
	show_playlist_urls 	=> 0,
	titles_only			=> 0,
);

#Search url
#http://www.youtube.com/results?search_query=<word+word+word>

#playlist url
#http://www.youtube.com/playlist?list=<id>

#Get options
my $args = join(' ', @ARGV);
my ($ret, $rem) = GetOptionsFromString($args, (
	"help|h" 					=> \$options{help}, 
	
	"file|f=s"   				=> \@{$options{files}},
	"url|u|id|i=s"				=> \@{$options{urls}},

	"overwrite|o"				=> \$options{overwrite},
	"dont-delete|dd"			=> \$options{dont_delete},
	
	"threads|tc=i"				=> \$options{threads},
	"useragent|ua=s" 			=> \$options{useragent},
	"timeout|t=i"				=> \$options{timeout},
	"proxy|p=s"					=> \$options{proxy},
	
	"parse-playlist|pp=s"		=> \$options{parse_playlist},
	"ids-only|io"				=> \$options{ids_only},
	"playlist-urls|pu"			=> \$options{show_playlist_urls},
	
	"download-playlist|dp=s" 	=> \$options{download_playlist},
	
	"titles-only|to" 			=>	\$options{titles_only},
));

unless($ret){
	exit;
}

if($options{help}){
	&show_help;
}
if(defined $options{proxy}){
	unless($options{proxy} =~ /^(socks|http)\:\/\/(.+)\:\d+$/){
		die "Invalid proxy format. Valid format: <socks|http>://<address|ip>:<port>\n";
	}else{
		print "Using proxy: $options{proxy}\n";
	}
}
if(defined $options{parse_playlist}){
	parse_playlist($options{parse_playlist});
	exit;
}elsif(defined $options{download_playlist}){
	download_playlist($options{download_playlist});
	exit;
}
unless(@{$options{files}} || @{$options{urls}}){
	print "No download source supplied\n";
	exit;
}
unless($options{threads} >= 1){
	die "Thread count must be greather than or equal to 1\n";
}
#else{
#	print "Using $options{threads} threads\n";
#}
if($options{overwrite}){
	print "Overwriting files if they exist\n";
}

unless(-e $file_dir){
	unless(create_dir($file_dir)){
		die "Unable to create download directory: $file_dir\n$!\n";
	}
}elsif(-e $file_dir && !-d $file_dir){
	die "Error: \"$file_dir\" exists but is not a directory\n";
}

my %urls = ();
my @url_info = ();

extract_from_array(@{$options{urls}});
extract_from_files(@{$options{files}});

unless(%urls){
	die "No URLs found...\n";
}

print "Found ", scalar keys %urls, " urls\n\n";

enum_titles;
#print Dumper(\@url_info);
unless(@url_info){
	die "Unable to obtain url info\n";
}
if($options{titles_only}){
	print "\n";
	for my $url(sort{lc($a->{title}) cmp lc($b->{title})} @url_info){
		print $url->{id} . "\t" . $url->{title} . "\n";
	}
	exit;
}

print "\nFound info for ", scalar @url_info, " URLs\n\n";

my @success :shared;
my @failed :shared;


my $pool = Thread::Pool::Simple->new
(
	min		=> 3,
    max		=> 5,
	load	=> 15,
	#min	=> $options{threads},
	#max	=> $options{threads},
	#load	=> $options{threads},
	do		=> [\&fetch_video],
);

for my $url(@url_info){
	unless($options{overwrite}){
		if(-e $url->{filename}){
			print "Skipping: " . $url->{filename} . "\n";
			next;
		}
	}
	$pool->add($url->{id}, $url->{filename});
}
print "\nAll downloads started...\n\n";
$pool->join();
#undef $pool;
	
print "\nDone\n";

if(@success){
	print "\nDownloaded:\n";
	for my $res(sort{lc($a->{filename}) cmp lc($b->{filename})} @success){
		print "\t" . $res->{id} . "\t" . $res->{filename} . "\n";
	}
}
if(@failed){
	print "\nFailed to download:\n";
	for my $res(sort{lc($a->{filename}) cmp lc($b->{filename})} @failed){
		print "\t" . $res->{id}, "\t" . $res->{filename} . "\n";
	}
	
	my $fail_file = $main_dir . "failed.txt";
	print "\nSaving failed ids to: $fail_file\n";
	open(F, '>>', $fail_file) or die "Unable to open file \"$fail_file\": $!\n";
	for my $res(sort{lc($a->{filename}) cmp lc($b->{filename})} @failed){
		print F $res->{id} . "\n";
	}
	close(F);
}


sub fetch_video
{
	local $SIG{KILL} = sub { exit; };
	
	my $id = $_[0];
	my $filename = $_[1];
	print "Downloading: $filename\n";
	
	my $result = {};
	share($result);
	$result->{filename} = $filename;
	$result->{id} = $id;
	
	my $client = WWW::YouTube::Download->new;
	$client->ua->agent($user_agent);
	$client->ua->timeout($time_out);
	if(defined $options{proxy}){
		$client->ua->proxy(['http', 'https'] => $options{proxy}); 
	}
	eval
	{
		open(F, '>', $filename) or die "couldn't open file: $!";
		binmode(F, ':raw');
		$client->download(
			$id, {
				cb => sub { 
					print F $_[0]; 
				}
			}
		);
		close(F) or die "couldn't close file: $!";
	
		#$client->download(
		#	$id, {
		#		filename => $filename,
		#	}
		#);
	};
	if(my $err = $@)
	{
		print "\tERROR: $err";
		unless($options{dont_delete}){
			if(-e $filename){
				if (unlink($filename) == 0) {
					print "\tERROR: can't delete $filename: $!\n";
				}else{
					print "\tDELETED: $filename\n";
				}
			}
		}
		push(@failed, $result);
	}else{
		print "Completed: $filename\n";
		push(@success, $result);
	}
	
	my $p = scalar @failed + scalar @success;
	print "\tStatus: $p\/", scalar @url_info, " completed\n";
}

sub enum_titles
{
	my @ids = keys %urls;
	my @tmp = ();

	while(my @chunk = splice(@ids, 0, 10)){
		@{$tmp[@tmp]} = @chunk;
	}
	for(my $i = 0; $i < @tmp; $i++){
		my @threads = ();
		for my $url(@{$tmp[$i]}){
			push(@threads, threads->create({'exit' => 'thread_only'}, \&fetch_title, $url));
		}
		
		while(my @running_threads = threads->list(threads::all)){
			usleep(200);
			for my $thr(@running_threads){
				if($thr->is_joinable){
					my ($r) = $thr->join;
					#print Dumper($r);
					if(defined $r){
						unless($options{titles_only}){
							print $r->{id} . " - " . $r->{filename} . "\n";
						}
						push(@url_info, $r);
					}
				}
			}
		}
		undef @threads;
	}
}

sub fetch_title
{
	local $SIG{KILL} = sub { exit; };
	
	my $id = $_[0];
	my $res = {};
	$res->{id} = $id;
	$res->{filename} = undef;
	
	my $client = WWW::YouTube::Download->new;
	$client->ua->agent($user_agent);
	$client->ua->timeout($time_out);
	if(defined $options{proxy}){
		$client->ua->proxy(['http', 'https'] => $options{proxy}); 
	}
	my $prep; 
	eval{$prep = $client->prepare_download($id)};
	if($@){
		print "ERROR: error fetching title for \"$id\"\n\t$@\n";
		undef $client;
		return undef;
	}else{
		my $title = $prep->{title};
		unless(defined $title){
			$res->{filename} = $id;
		}else{
			$res->{filename} = &clean_encode($title);
		}
		$res->{title} = $title;
		#print Dumper($prep),"\n";
		my $suffix = $prep->{suffix};
		if(defined $suffix){
			$res->{filename} .= ".$suffix";
		}
		$res->{filename} = $file_dir . $res->{filename};
		undef $client;
		return $res;
	}
}

sub extract_from_array(@)
{
	for my $url(@_){
		my $id = parse_url($url);
		unless(defined $id){
			print "Unable get id from: $url\n";
			next;
		}
		$urls{$id}++;
	}
}

sub extract_from_files(@)
{
	foreach my $file(@_){
		unless(-e $file && -f $file){
			die "Error: $file does not exist\n";
		}

		my @file_lines = read_file($file);
		foreach my $line(@file_lines){
			my $id = parse_url($line);
			unless(defined $id){
				print "Unable get id from: $line\n";
				next;
			}
			$urls{$id}++;
		}
	}
}

sub read_file($)
{
	my @lines = ();
    open (F, '<', $_[0]) or die "Could not open $_[0]!\n";
    while (my $line = <F>)
    {
        chomp($line);
		$line =~ s/^\s+|\s+$//g;
		next unless length $line;
		push(@lines, $line);
    }
    close (F);
	return @lines;
}

sub parse_url($)
{
	if($_[0] =~ m/youtube\.com\/watch\?v\=([A-z0-9_-]+)/i){
		return $1;
	}elsif($_[0] =~ m/youtu\.be\/([A-z0-9_-]+)/i){
		return $1;
	}elsif($_[0] =~ m/^([A-z0-9_-]+)$/i){
		return $1;
	}else{
		return undef;
	}
	
}

sub clean_encode($)
{
	my $str = $_[0];
	$str = HTML::Entities::decode_entities($str);
	$str =~ s/([^A-Za-z0-9\-_.()\[\]])/ /g;
	$str =~ s/\&/and/g;
	$str =~ s/([()\[\]])/ $1 /g;
	$str =~ s/\s{2,}/ /g;
	$str =~ s/^\s+|\s+$//g;
	$str = join('', map{ucfirst(lc($_))} split(/(\s+)/, $str));
	#$str = join'', map { ucfirst lc } split /(\s+)/, $str;
	$str =~ s/(\()\s+/$1/g;
	$str =~ s/\s+(\))/$1/g;
	$str =~ s/(\[)\s+/$1/g;
	$str =~ s/\s+(\])/$1/g;
	$str =~ s/\_+/ \- /g;
	$str =~ s/\s{2,}//g;
	return $str;
}

sub cd(;$)
{
	my $dir = $_[0];
	unless(defined $dir){
		(undef, $dir) = File::Basename::fileparse(Cwd::abs_path($0));
	}
	$dir =~ s/\\+/\//g;
	chdir($dir) or die "Can't change CWD directory to $dir\nError: $!\n";
	#print "Changed CWD to: \"$dir\"\n\n";
}

sub get_cwd
{
	my (undef, $dir) = File::Basename::fileparse(Cwd::abs_path($0));
	if(defined $dir){
		$dir =~ s/\\/\//g;
		if($dir !~ /\/$/){
			$dir .= "/";
		}
	}
	return $dir;
}

sub create_dir($)
{
	my $dir_to_create = $_[0];
	make_path(
		$dir_to_create,{
			error   => \my $err,
			verbose => 1
		}
	);
	if(@$err){
		for my $diag (@$err){
			my ($file, $message) = %$diag;
			if ($file eq ''){
					print "Error: $message\n";
			}else{
				print "Error: problem unlinking $file: $message\n";
			}
		}
		return 0;
	}
	else{
		print "Info: created $dir_to_create\n";
		return 1;
	}
}

sub parse_playlist($)
{
	my $playlist_file = $_[0];
	unless(defined $playlist_file && -e $playlist_file){
		die "Unable to locate \"$playlist_file\"\n";
	}
	
	my %found = ();
	open(F, '<', $playlist_file) or die "Unable to open \"$playlist_file\"\nError: $!\n";
	while(my $line = <F>)
	{
		my($id) = $line =~ m/href\=\"\/watch\?v\=(.+)\&amp\;list\=/i;
		unless($id){
			next;
		}
		
		my ($title) = $line =~ m/title\=\"(.+)\"\sclass\=/i;
		unless($title){
			next;
		}
		HTML::Entities::decode_entities($title);
		$title =~ s/[\r\n\t\?\|\\\/\*\&\^\%\$\#\!\-\=\_\+\;\.\,\"\']//g;
		$title =~ s/([\(\)\[\]])/ $1 /g;
		$title =~ s/\s{2,}/ /g;
		$title =~ s/^\s+|\s+$//g;
		
		$title = join '', map { ucfirst lc } split /(\s+)/, $title;
		$found{$id} = $title;
	}
	close(F);
	
	unless(%found){
		print "Nothing found\n";
	}
	else
	{
		for my $f(sort{lc($found{$a}) cmp lc($found{$b})} keys %found)
		{
			if($options{ids_only}){
				print "$f\n";
			}elsif(!$options{show_playlist_urls}){
				print "$f\t$found{$f}\n";
			}else{
				print "http://youtu.be/$f\t$found{$f}\n";
			}
		}
	}
}

sub download_playlist($)
{
	my $file_url = $_[0];
	#http://www.youtube.com/playlist?list=<playlist_id>
	unless(defined $file_url && $file_url =~ /^(htt(p|ps))\:\/\/(?:(www\.)?)(youtube\.com|youtu\.be)\/playlist\?list\=(.+)$/i){
		die "Invalid playlist URL:\n$file_url\nValid format: http://www.youtube.com/playlist?list=<playlist_id>\n";
	}
	
	my ($file_name) = $file_url =~ m/\?list\=([a-z0-9\-\_]+)$/i;
	unless(defined $file_name){
		die "Unable to parse filename from URL\n";
	}
	$file_name = $main_dir . "playlist-" . $file_name . ".html";
	
	my $module = "WWW::Mechanize";
	eval {eval "use $module; 1" or die "$@";};
	if(my $err = $@){
		die "use $module module FAILED\nPlease install the module $module and try again\n";
	}
	
	my %mech_options = 
	(
		agent           => '', 		
		autocheck       => 0,  		
		cookie_jar      => undef, 	
		conn_cache		=> undef,
		noproxy         => 1, 
		quiet			=> 1,
		show_progress   => 1,  		
		stack_depth     => 0,  		
		timeout         => 30,
	);
	my $mech = WWW::Mechanize->new(%mech_options);
	if(defined $options{proxy}){
		$mech->proxy(['http', 'https'] => $options{proxy}); 
	}
	
	print "Download playlist: $file_url\nSaving to: $file_name\n";
	my $response = $mech->get($file_url);
	unless($mech->success()){
		print "Error: $file_url\n\t|_-> Unable to fetch page ",  $response->status_line,"\n\n";
	}else{
		$mech->save_content($file_name);
		print "Saved $file_url\n\t|_-> $file_name\n\n";
	}
	
}

sub show_help
{
print <<EOL;

Options:
   -dd, -dont-delete                       - If a video download fails, the file is deleted by default.
                                             Use this option if you don't want the video to be deleted.
   -dp, -download-playlist <playlist url>  - Downloads a playlist url and saves it to an HTML file.
   -f,  -file              <file>          - Specifies a file to look for ids/urls in. (can be used multiple times)
   -h,  -help                              - Shows this help menu.
   -i,  -id                <id>            - Specifies a video id to download. (can be used multiple times)
   -io, -ids-only                          - Only show video ids when parsing a playlist file.
   -o,  -overwrite                         - Overwrite files if they already exist when downloading.
   -p,  -proxy             <proxy>         - Use a proxy when downloading. 
                                             Valid fomat: <socks|http>://<host|ip>:port
   -pp, -parse-playlist    <file>          - Extracts ids and titles from an HTML playlist file.
   -pu, -playlist-urls                     - When parsing an HTML playlist file, this will show links to the video.
   -t,  -timeout           <timeout>       - Sets the timeout for downloading.
   -tc, -threads           <number>        - Number of threads to use at a time. Default is 4. Minimum of 1.
   -to, -titles-only                       - Only gets the titles of the videos and lists them.
   -u,  -url               <url>           - A URL to download videos from. (can be used multiple times)
   -ua, -useragent         <string>        - Specifices a useragent string to use when downloading.

EOL
exit;
}

END {
	my @running_threads = threads->list(threads::all);
	if(scalar(@running_threads) > 0){
		print "Performing cleanup\n";
		while(scalar(@running_threads) > 0){
			for my $thr(@running_threads){
				eval{
					my $tid = $thr->tid();
					if($thr->is_joinable){
						$thr->join;
						print "Thread $tid joined\n";
					}else{
						$thr->kill('KILL')->detach;
						print "Thread $tid killed\n";
					}
				};
				if(my $err = $@){
					print "Error stopping thread: $err\n";
				}
			}
			@running_threads = threads->list(threads::all);
		}
		print "Cleanup done\n";
	}
}
