# Ansible Role: upload_cloud_image

This role handles the download and upload of an Ubuntu cloud-init image for
Proxmox VM creation.

## Purpose

- Downloads a cloud-init-enabled Ubuntu Server image (default: 22.04 LTS).
- Uploads the image to your Proxmox host into the `/var/lib/vz/template/qemu/`
  directory.
- Skips download or upload if the image is already present.

## Directory

Cloud images will be stored locally in: {{ playbook_dir }}/cloud-images/

## Role Variables

| Variable               | Description                                           | Default                                                      |
| ---------------------- | ----------------------------------------------------- | ------------------------------------------------------------ |
| `cloud_image_url`      | URL to download the cloud-init-enabled Ubuntu image   | `https://cloud-images.ubuntu.com/jammy/current/...amd64.img` |
| `cloud_image_filename` | The filename to use locally and on the Proxmox server | `ubuntu-22.04-cloud.img`                                     |

## Requirements
	•	Proxmox host must be reachable and writable at /var/lib/vz/template/qemu/.
	•	Ansible must be run from a control machine that has internet access.

## Notes
	•	Uses delegate_to: localhost for downloading the image.
	•	Uses delegate_to: pve (or your Proxmox inventory hostname) for uploading to Proxmox.
	•	Skips uploading if the file already exists on Proxmox.
