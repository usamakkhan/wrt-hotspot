#!/usr/bin/env python3
"""Run a shell command on an emulated router through its QEMU serial port.

usage: console.py PORT [--wait-boot SECS] [CMD...]
Each CMD is sent as one line; output up to a unique end marker is printed.
"""
import socket, sys, time, uuid

def read_until(s, needle, timeout):
    buf = b''
    end = time.time() + timeout
    while time.time() < end:
        s.settimeout(max(0.1, end - time.time()))
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        if not d:
            break
        buf += d
        if needle in buf:
            return buf, True
    return buf, False

def main():
    port = int(sys.argv[1])
    args = sys.argv[2:]
    wait = 0
    if args[:1] == ['--wait-boot']:
        wait = int(args[1]); args = args[2:]
    end = time.time() + max(wait, 5)
    while True:
        try:
            s = socket.create_connection(('127.0.0.1', port), timeout=5)
            break
        except OSError:
            if time.time() > end:
                sys.exit('cannot connect to serial port %d' % port)
            time.sleep(1)
    if wait:
        # Poke the console until a shell answers.
        deadline = time.time() + wait
        while time.time() < deadline:
            s.sendall(b'\r\n')
            m = uuid.uuid4().hex[:8]
            s.sendall(('echo RD""Y%s\n' % m).encode())
            buf, ok = read_until(s, ('RDY%s\r\n' % m).encode(), 5)
            if ok:
                break
        else:
            sys.exit('router shell did not answer within %ds' % wait)
    rc = 0
    for cmd in args:
        m = uuid.uuid4().hex[:8]
        # Leading newline clears any partial line; marker carries the exit code.
        # Quote-split marker so the console's echo of this line never matches.
        line = '%s; echo "EN""D%s rc=$?"\n' % (cmd, m)
        s.sendall(line.encode())
        buf, ok = read_until(s, ('END%s rc=' % m).encode(), 900)
        out = buf.decode('utf-8', 'replace')
        # Drop everything up to and including the echoed command line.
        echo = out.find('D%s rc=$?"' % m)
        first = out.find('\n', echo) if echo >= 0 else out.find('\n')
        body = out[first + 1:] if first >= 0 else out
        idx = body.rfind('END' + m)
        tail = body[idx:]
        print(body[:idx].replace('\r', ''), end='')
        if not ok:
            print('[timeout]'); rc = 1
        else:
            more, _ = read_until(s, b'\n', 3)
            code = (tail + more.decode('utf-8', 'replace')).split('rc=')[1].split()[0]
            if code != '0':
                rc = int(code) if code.isdigit() else 1
    s.close()
    sys.exit(rc)

main()
