This is pre-built packages for RISCV64 architecture. It included **GOLang**, **ipfs** and **go2rtc** packages.

Also, here is dockerfile from which the image is built. 
## Versions 
```commandline
$ go version
go version go1.24.0 linux/riscv64
```
```commandline
$ ./go2rtc --version
go2rtc version 1.9.9 (mod.fa580c5) linux/riscv64
```
```commandline
$ ./ipfs --version
ipfs version 0.33.2
```
## GO Lang install
To install go on your Risc-v, run next commands:
```commandline
tar vxf go1.24.0.linux-riscv64.tar -C /usr/local
# Add to your PATH
export PATH="/usr/local/go/bin:$PATH"
# Add to bashrc
echo "export PATH=/usr/local/go/bin:$PATH" >> ~/.bashrc
```

## go2rtc install
This is pre-built binary. Put it in any `bin` directory in PATH. For example:
```commandline
sudo cp go2rtc_riscv64 /usr/local/bin/go2rtc
```

## IPFS isntall
This is pre-built binary. Put it in any `bin` directory in PATH. For example:
```commandline
sudo cp ipfs_riscv64 /usr/local/bin/ipfs

```
