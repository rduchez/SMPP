# SMPP iRule

This iRule was created with input from existing implementation for support of the SMPP protocol on F5 BIG-IP.

Requirements for this irule are as follows:
1. Long lived SMPP binds (on both sides preferably, but hard requirement on the source side)
2. Ability to send fragments of a multipart message to same downstream host (we need this for message assembly reasons) using message metadata
3. Use protocol level heartbeat (e.g enquire_link packets) to determine liveness of binds to SMPP hosts

The configuration of the BIG-IP needs to be altered to add the mblb profile: 
create ltm profile mblb /Common/mblb_smpp ingress-high 10000 ingress-low 9000 min-conn 0 tag-ttl 60
modify ltm virtual SMPP_VS/serviceMain profiles add { /Common/mblb_smpp }

be careful any resubmitting of the as3 declaration will result in this configuration being discarded. 

the iRule has been tested with:
multiple binds
multiple requests

When submitting multiple requests, requests are spread out evenly accross the 2 pool members.  With the current test bed, 10k request from 2 instances, the resulting traffic was spread evenly accross both pool members. 

Trying to do multi part message - opensmpp tool may not be sufficient at this stage. 

Consists of generating requests accross 2 servers using smppsim and opensmpp

The AS3 decalration does not include the mblb configuration at present - issue #94 was posted to perspective https://github.com/F5Networks/f5-appsvcs-extension/issues/94

