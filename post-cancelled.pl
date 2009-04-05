#!/usr/local/bin/perl -w
#
# post-cancelled.pl - A program to repost files that may have been
# cancelled by colt38.pl.  
#
# Here are some notes from Mike on the topic.  I've gone through and
# cleaned up the headers in the files that we determined needed salvation.
# 
# change message-id - prepend <repost-[orignal message id]>
# change date to current date
# remove us.jobs*
# remove biz.jobs.offered
# remove biz.jobs.offerd
# 
# Thanks!
# 
# (if you post from porthos you can post into chippy directly via
# 'ihave' protocol)
# 
# (if you post from pooh, use news.visi.com and use the 'post' protocol)
# 
# a minimal amount of finangling retromoderate any newsgroup with the
# appropriate rule set.
#
# steve ulrich <sulrich@botwerks.org>
#
# The term colt38 came from a truly braindead posting made by a 
# paranoiac by the name of Mike Schneider.  Revenge through geekiness ;-)
#

use News::NNTPClient;

my %settings = (
		NEWSSERVER => 'news.visi.com',
		NEWSPORT   => 'nntp',
		GROUP      => 'mn.jobs'
	       );

$client = new News::NNTPClient("$settings{NEWSSERVER}", 
			       "$settings{NEWSPORT}");


foreach my $file (@ARGV) {
  open(ARTICLE, $file) || die " Error opening $file";
  my @article = <ARTICLE>;
  close(ARTICLE);

  # print  @Article;
  $client->post(@article);
}
