Reloading tasks affecting ES:

  rake task:legislators && rake task:committees

  rake task:bills_thomas debug=1 session=112 && rake task:bills_thomas debug=1 session=111

	rake task:bill_text_archive debug=1 session=112 && rake task:bill_text_archive debug=1 session=111

  rake task:amendments_archive debug=1 session=112 && rake task:amendments_archive debug=1 session=111

	rake task:votes_house year=2012 debug=1 && rake task:votes_house year=2011 debug=1 && rake task:votes_house year=2010 debug=1 && rake task:votes_house year=2009 debug=1 

	rake task:votes_senate year=2012 debug=1 && rake task:votes_senate year=2011 debug=1 && rake task:votes_senate year=2010 debug=1 && rake task:votes_senate year=2009 debug=1

	rake task:house_live archive=True captions=True && rake task:house_live archive=True captions=True senate=True