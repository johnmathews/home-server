`iperf3` is a network testing utility. It runs on the Proxmox server and also on a client, like your laptop.

Make a connection between the server and the client and you can test the speed of the connection between them.

## Server setup

There is an instance of `iPerf3` running in a container on the Infra VM.

The service definition is:

```
  iperf3:
    image: networkstatic/iperf3
    container_name: iperf3
    restart: unless-stopped
    command: -s
    ports:
    - "5201:5201"  # TCP
    - "5201:5201/udp"  # UDP
```

## Client setup

You need to also install `iPerf3` on your laptop.

You can use `brew install iperf3`.

Then run the command above.

## Testing

Use this command to test how well you can stream movies from the server to your laptop at your current location:

```sh
iperf3 -c 192.168.2.106 -R -u -b 400M -t 30
```

Use this command to measure the quality of your WiFi signal and router/antenna placement:

```sh
iperf3 -c 192.168.2.106 -R -t 30 -b 300M
```
