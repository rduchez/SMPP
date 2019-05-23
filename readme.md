# SMPP iRule

This configuration relies on the Message Routing Framework 

A sample configuration is provided.  This includes:

-iRule for processing messages
-datagroup to work in conjunction with the iRule configuration
-MRF router, transport, and peer objects (ref. https://techdocs.f5.com/kb/en-us/products/big-ip_ltm/manuals/product/bigip-service-provider-generic-message-administration-13-0-0.html)
-pool for SMSC configuration and designation
-virtual server to setup a listener on BIG-IP that will process the incoming ESME connection
-other ancillary configuration

Note that the AS3 declaration does not configure the VS end-to-end the main missing piece is the MRF configuration 

This iRule was created with input from existing implementation for support of the SMPP protocol on F5 BIG-IP.

Requirements for this irule are as follows:
1. Long lived SMPP binds (on both sides preferably, but hard requirement on the source side)
2. Ability to send fragments of a multipart message to same downstream host (we need this for message assembly reasons) using message metadata
3. Use protocol level heartbeat (e.g enquire_link packets) to determine liveness of binds to SMPP hosts


Testing:
this was achieved generating requests accross 2 servers using smppsim and opensmpp.
a generic test script is used for concatenate messages using Python the SMPPLib 
This configuration was tested and is known to work on TMOS v. 13.1

Appendix - reference for testing

running SMPP in the prebuilt docker container
sudo docker run -d -p 2775:2775 -p 88:88 --name smppsim --rm wiredthing/smppsim


template used for testing
https://s3.amazonaws.com/f5-cft/f5-existing-stack-byol-2nic-bigip.template

To install, run and stop the smppsim using the available smppsim container

sudo apt-get install docker.io
sudo docker run -d -p 2775:2775 -p 88:88 --name smppsim --rm wiredthing/smppsim
sudo docker ps
sudo docker run -d -p 2776:2775 -p 89:88 --name smppsim --rm wiredthing/smppsim
sudo docker run -d -p 2776:2775 -p 89:88 --name smppsim2 --rm wiredthing/smppsim
sudo docker stop smppsim

resources: 
https://clouddocs.f5.com/api/irules/GENERICMESSAGE.html
https://clouddocs.f5.com/api/irules/MR.html
https://techdocs.f5.com/kb/en-us/products/big-ip_ltm/manuals/product/bigip-service-provider-generic-message-administration-13-0-0/1.html
