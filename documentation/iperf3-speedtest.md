# iPerf3

`iperf3` is a network testing utility. It runs on the server and also on your
laptop. Make a connection and you can test the speed of the connection between
the devices.

Use this command to test how well you can stream movies from the server to your
laptop at your current location:

```sh
iperf3 -c 192.168.2.106 -R -u -b 400M -t 30
```
