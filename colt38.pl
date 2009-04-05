#!/usr/local/bin/perl -w
#
# colt38.pl - A program to retromoderate the mn.* hierarchy and with
# a minimal amount of finangling retromoderate any newsgroup with the
# appropriate rule set.
#
# steve ulrich <sulrich@botwerks.org> 
#
#
# The term colt38 came from a truly braindead posting made by a paranoiac
# by the name of Mike Schneider.
#
# this was initially supposed to run as a daemon.  much of this code has
# been removed due to some bugs that i ran across but never bothered to
# fix.  it's operation as a command line client is fully functional though.


use News::NNTPClient;
use File::Path;

# Define a Variety of site specific stuff here 
$|               = 1;  # No Buffering
$debug           = 0;
$ConfigFile      = $ARGV[0];
my $NewsClient   = "";
my %Settings     = ();
my %lastArtCount = ();
my %GroupLimit   = ();

# Define the SIGNAL's that we'll pay attention to 
$SIG{HUP}  = \&catchHUP; # Reread our configuration file and start again
$SIG{QUIT} = \&dieWGrace; 
$SIG{INT}  = \&dieWGrace; 
$SIG{TERM} = \&dieWGrace; 
$SIG{ALRM} = \&dieWGrace; 
$SIG{KILL} = \&dieWGrace; 

#-------------------------------------------------------------------
# Here are the guts of things.
#
# Open and redirect STDERR and STDOUT
# open (STDOUT, ">>logs/colt38.out") || die "Cannot redirect STDOUT";
# open (STDERR, ">>logs/colt38.err") || die "Cannot redirect STDERR";
open (CANLOG, ">>$Settings{CANCELLOG}") || die "Cannot open Cancel Log";
&mainLoop;

#-------------------------------------------------------------------
#
# mainLoop()
# Where all the action is Jackson 
#
sub mainLoop {
#  while () {
    &initClient;
    &getNewArtCount;
    
    foreach $CheckGroup (sort(keys(%GrpsToCheck))) {
      print STDERR "----*** Group: ", $CheckGroup, "\n" if $debug > 0;
      &checkGroup($CheckGroup);
      &writeGroupList; 
    }
    &writeGroupList; 
#    sleep($Settings{SLEEPTIME});
#  }
}   # End of sub mainLoop



#-------------------------------------------------------------------
#
# initClient() 
# Initialize the various and unsundry variables that will make life
# happy.
#
sub initClient {
  %GrpsToCheck 	= ();   # intialize the Groups to check hash    
  %Settings    	= &getSettings($ConfigFile);
  %lastArtCount = &getGroupList($Settings{GROUPFILE});
  %GroupLimit   = &getGroupLimit($Settings{GROUPFILE});

  print STDERR "Reading Configuration File: ", `date` if $debug > 0;

  # Get the Cancel Message Body
  $Settings{MESSAGE} = &getTemplate($Settings{MESSAGEFILE});
  
  # We also need to check to make sure that we have a connection
  # to the news server.  If there isn't a connection or our NewsClient 
  # isn't happy we should sleep for a little while and attempt to connect
  # again.
  
  $NewsClient = new News::NNTPClient("$Settings{NEWSSERVER}", 
				     "$Settings{NEWSPORT}");
   
} # End of sub initClient


# -------------------------------------------------------------------
#
# catchHUP()
# 
# Catch the HUP signal.  Basically reinitialize the variables and 
# run again
#
sub catchHUP {  
  print STDERR "\nRestarting colt38\n";
  &initClient;
  print STDERR "\n--Rereading configuration file $ConfigFile\n" if $debug > 0;
  &mainLoop;
}





# -------------------------------------------------------------------
#
# checkGroup(GroupName)
# Cycle through the group and look at the articles that have been 
# posted since the last time we looked at this group. 
#
sub checkGroup {
  my ($Group) = @_;
  
  my ($GrpFirst, $GrpLast) = $NewsClient->group($Group);  

  # Go to the last article that we've seen
  my $StatArtID = $NewsClient->stat($lastArtCount{$Group}); 
  print STDERR "StatArtID: ", $StatArtID, "\n" if $debug > 0;

  my $MessageCounter = $lastArtCount{$Group};
  print STDERR "Starting Article:-",$lastArtCount{$Group},"-\n" if $debug > 0;

  $lastArtCount{$Group} = $GrpLast;
  print STDERR  "--$Group: $lastArtCount{$Group}\n" if $debug > 0;

 ARTICLE: while ($NewsClient->next) {

    if ($debug > 1) {
      print STDERR 
	"Message Retrieved\n -- Group: $Group\n -- $MessageCounter\n";
    }
    $MessageCounter++;
    my %Headers = ();
    my @ArtHead = $NewsClient->head();
    
    foreach $_ (@ArtHead) {
      my $FirstColon = index($_, ": ");
      my $Header  = substr($_, 0, $FirstColon);
      my $Content = substr($_, $FirstColon + 2, length($_));
      chop($Content) if ($Content ne "");
      $Headers{$Header} = $Content;
    }
    
    my $ArtStatus = &parseNewsgroups($Headers{Newsgroups}, $Group);
    next ARTICLE if ($ArtStatus == 0); # It's OK
    
    # This baby needs to be cancelled.
    &saveArticle($Group, $MessageCounter, $NewsClient->article);
    my $CancelMsg = &createCMesg($Headers{'Newsgroups'},
				 $Headers{'Message-ID'}, 
				 $Headers{'From'},
				 $Headers{Subject});

    # Post the Cancel Message, but first tokenize it into an array blech
    my $currentTime = localtime(time);
    print CANLOG "Cancelling: [$currentTime]\t$Headers{'Message-ID'}\t$Headers{'Newsgroups'}\t$Headers{'From'}\n";
    my @CMesgArray = split('\n', $CancelMsg);
    $NewsClient->post(@CMesgArray);
  }
  # We need to set the value of the last article for the group
}   # End of sub checkGroup


# -------------------------------------------------------------------
#
# saveArticle(Article)
# If we're going to cancel a posting we should first commit the posting
# to disk.  This will let us resurrect the posting at a later date. 
# should we really screw something up. ;-)
#
sub saveArticle {
  
  my ($Group, $MsgID, @Article)  = @_;  
  
  $Group =~ s/\./\//goi;
  mkpath("$Settings{BKUP_BASEDIR}/$Group", 1, 0755);
  
  open (POOPCHUTE, ">$Settings{BKUP_BASEDIR}/$Group/$MsgID") || 
    die "Error opening: $Settings{BKUP_BASEDIR}/$Group/$MsgID";
  print POOPCHUTE @Article, "\n";
  close(POOPCHUTE);
  
} # End of sub storeArticle

# -------------------------------------------------------------------
#
# parseNewsgroups(NewsGroups)
#
# This will look at the newsgroups header and check to see how many
# groups it's posted to. and specifically how many groups outside of
# the mn.* hierarchy.
# 
sub parseNewsgroups {
  my ($Header, $Group) = @_;
  
  $Header =~ s/\s//g;              # cleanout any whitespace    
  return 0 if ($Header !~ /\,/);   # additional groups
  
  my @GroupList = split(',', $Header);
  
  # -----------------------------------------------------------------
  # 
  # This section needs some serious attention - We want to have rulesets
  # that understand what we want to accomplish in a more general fashion.
  
  # This is crude and definitely needs to be fixed however it'll do in a 
  # pinch. ;-)
  my $CrossCount = 0; # Initialize the crossposting counter
  foreach $_ (@GroupList) {
    $CrossCount++ if ( $_ !~ /^$Settings{GUARDEDHIERARCHY}\./ );
  }
    
  #
  #
  # -----------------------------------------------------------------
  
  if  ($CrossCount > $GroupLimit{$Group} ) { 
    print STDERR "Crosscount: $CrossCount\n" if $debug > 0;
    return 1; 
  } else { return 0; }
  
} # End of sub parseNewsgroups

#-------------------------------------------------------------------
#
# getNewArtCount
# 
# This will query the news server to get the message count for the
# various groups that its interested in.  It will update a hash that
# we'll search through to do the cancellations.  By doing this 
# we only touch the groups that we're really interested in and 
# we minimize our interaction with the news server.
#
sub getNewArtCount {
  foreach $Group ( keys(%lastArtCount) ) {
    my ($first, $last) = $NewsClient->group("$Group");
    print STDERR "$Group: $first - $last\n" if $debug > 0;
    if ($last > $lastArtCount{$Group}) {
      print STDERR "Added $Group to CheckList: $last" if $debug > 1;
      $GrpsToCheck{$Group} = $lastArtCount{$Group};
    }
  } 
  
} # End of sub getNewArtCount


#-------------------------------------------------------------------
# 
# createCMesg()
#
# Actually formulate the cancel message and return the thing.
# 
sub createCMesg {
 my ($Newsgroups, $MsgID, $PrevFrom, $PrevSubject) = @_;

 $MsgID =~ s/[<|>]//goi;
 my $CancelMessage = <<EOF;
Path: $Settings{NEWSPATH}
From: $PrevFrom
Message-ID: <cancel.$MsgID>
X-Cancelled-by: $Settings{XCANCELLEDBY}
Subject: cmsg cancel <$MsgID>
Newsgroups: $Newsgroups
Control: cancel <$MsgID>
User-Agent: $Settings{USERAGENT}
Summary: $Settings{SUMMARYTXT}
Approved: $Settings{APPROVED}
X-No-Archive: Yes
X-Was-From: $PrevFrom
X-Was-Subject: $PrevSubject

$Settings{MESSAGE}
EOF

if ($debug > 1) {
 print STDERR 
   "\n------------------------------------------------------------\n";
 print STDERR $CancelMessage, "\n";
 print STDERR 
   "\n------------------------------------------------------------\n";
}
 
 return $CancelMessage;
}



#-------------------------------------------------------------------
# writeGoupList()
#
# Write the  most recent values of things to disk so we can 
# use them later on in life.
#
sub writeGroupList {
  open (GROUPLIST, ">$Settings{GROUPFILE}") || 
    die "Cannot open $Settings{GROUPFILE}";
  foreach $Group (sort(keys(%lastArtCount))) {
    print GROUPLIST "$Group:$lastArtCount{$Group}:$GroupLimit{$Group}\n";
  }
  close(GROUPLIST);
} # End of sub writeVars



#-------------------------------------------------------------------
# dieWGrace()
#
# Catch the KILL signal and die with grace.
# 
sub dieWGrace {
  print STDERR "Dying off with Grace\n";
  &writeGroupList;
  close(CANLOG); # Close the cancel log
  close(STDOUT); # Turn off the redirection of STDOUT
  close(STDERR); # Turn off the redirection of STDERR
  exit(0); 
} # end of sub dieWGrace()




# -------------------------------------------------------------------
# getSettings(ConfigFile)
#
# Load the settings from a configuration file and return the values 
# in the settings hash.
# 
sub getSettings {
  my ($ConfigFile ) = @_;
  my $Settings = ();
  
  open (CONF, "$ConfigFile") || die "Unable to open $ConfigFile";
  while (<CONF>) {
    next if /^\#/;
    my ($Var, $WSpace, $WSpace,$Value) = /^(\S+)(\s+)=(\s+)\"(.+)\"$/;
    # Let's Turn our Vars into UpperCase Vars for readability and 
    # make us fairly agnostic wrt the capitalization of the Vars.
    $Var =~ tr/a-z/A-Z/;
    $Settings{$Var} = $Value;
  }
  close(CONF);
  
  if ($debug > 0) {
    print STDERR "\n\n", '=' x 70, "\n";
    foreach (keys(%Settings)) {
      print STDERR "$_ - $Settings{$_}\n";
    }
    print STDERR '=' x 70, "\n";
  }

  return %Settings;
}

# -------------------------------------------------------------------
# getTemplate(TemplateFile)
#
sub getTemplate {
    my $TemplateFile = $_[0];
    my $Template     = "";

    open(TEMPLATE, $TemplateFile) || die "Error Opening: $TemplateFile";
    while(<TEMPLATE>) { $Template .= $_; }
    close(TEMPLATE);

    return $Template;
}


# -------------------------------------------------------------------
# getGroupList(GroupList)
#
# Load the List of groups from a configuration file and return the
#  values in the GroupList hash.
# 
sub getGroupList{
  my ($GroupFile ) = @_;
  my %GroupList = ();
  
  open (GROUPS, "$GroupFile") || die "Unable to open $GroupFile";
  while (<GROUPS>) {
    next if /^\#/;
    next if /^$/;
    print STDERR $_ if $debug > 1;
    my $GroupLine = $_;
    $GroupLine =~ s/\s//g;
    my ($Group, $LastMsgNum) = split(/:/, $GroupLine);
    $LastMsgNum =~ s/\r|\n|\s//g;    # Rip out whitespace
    $GroupList{$Group} = $LastMsgNum;
  }
  close(GROUPS);

  return %GroupList;
}


#-------------------------------------------------------------------
# getGroupLimit(GroupList)
#
# Load the List of groups from a configuration file and return the
# values in the GroupLimit hash.
# 
sub getGroupLimit{
  my ( $GroupFile ) = @_;
  my %GroupLimit = ();
  
  open (GROUPS, "$GroupFile") || die "Unable to open $GroupFile";
  while (<GROUPS>) {
    next if /^\#/;
    next if /^$/;
    print STDERR $_ if $debug > 1;
    my $GroupLine = $_;
    $GroupLine =~ s/\s//g;
    my ($Group, $LastMsgNum, $GroupLimit) = split(/:/, $GroupLine);
    $LastMsgNum =~ s/\r|\n|\s//g;    # Rip out whitespace
    $GroupLimit{$Group} = $GroupLimit;
  }
  close(GROUPS);

  return %GroupLimit;
}
