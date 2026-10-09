MRK3399 config partition
========================

This small FAT partition holds everything that makes a node *this* node. It is
kept when the node is reset (mrk-reset) or upgraded over the network; the OS
partition and the Kubernetes data are not.

  node.conf         host name, address, NTP, lab server -- edit this
  authorized_keys   SSH public keys

Created on the node at first boot, then kept:

  identity/         machine-id and SSH host keys, so the node keeps the same
                    identity across resets (delete the directory to make it a
                    "new" machine on the next boot)

To prepare an image for one node before flashing, see docs/k8s-lab.md
("make node-image"), or mount this partition and edit the files.
