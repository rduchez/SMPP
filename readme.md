#SMPP iRule

Requirements for this irule are as follows:
1. Long lived SMPP binds (on both sides preferably, but hard requirement on the source side)
2. Ability to send fragments of a multipart message to same downstream host (we need this for message assembly reasons) using message metadata
3. Use protocol level heartbeat (e.g enquire_link packets) to determine liveness of binds to SMPP hosts

The aim is to support the SMPP stack in an intelligent manner on F5's BIG-IP through an Irule. More to come. 