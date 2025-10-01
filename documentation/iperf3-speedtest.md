`iperf3` is a network testing utility. It runs on the server and also on your
laptop. Make a connection and you can test the speed of the connection between
the devices.

Use this command to test how well you can stream movies from the server to your
laptop at your current location:


```sh
iperf3 -c 192.168.2.106 -R -u -b 400M -t 30
```

## Setup

There is an instance of `iPerf3` running in a container on the infra vm. The service definition is:

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

You need to also install `iPerf3` on your laptop. You can use `brew install iperf3`.

Then run the command above.
