#!/usr/bin/env python3
"""
Simple mbpoll replacement using pymodbus
Implements the most common mbpoll functionality for the lab
"""
import sys
import argparse

try:
    from pymodbus.client import ModbusTcpClient
    PYMODBUS_VERSION = 3
except ImportError:
    from pymodbus.client.sync import ModbusTcpClient
    PYMODBUS_VERSION = 2

def main():
    parser = argparse.ArgumentParser(description='Simple Modbus polling tool (pymodbus wrapper)')
    parser.add_argument('-a', '--address', type=int, default=1, help='Slave address (default: 1)')
    parser.add_argument('-r', '--register', type=int, default=0, help='Starting register (default: 0)')
    parser.add_argument('-c', '--count', type=int, default=1, help='Number of registers (default: 1)')
    parser.add_argument('-t', '--type', type=int, default=4, help='Function code: 1=coils, 2=discrete, 3=holding, 4=input (default: 4)')
    parser.add_argument('host', help='Target host IP')
    parser.add_argument('-p', '--port', type=int, default=502, help='TCP port (default: 502)')

    args = parser.parse_args()

    client = ModbusTcpClient(args.host, port=args.port)

    if not client.connect():
        print(f"Failed to connect to {args.host}:{args.port}")
        sys.exit(1)

    slave_kwarg = {'slave': args.address} if PYMODBUS_VERSION >= 3 else {'unit': args.address}

    try:
        if args.type == 1:
            result = client.read_coils(args.register, args.count, **slave_kwarg)
        elif args.type == 2:
            result = client.read_discrete_inputs(args.register, args.count, **slave_kwarg)
        elif args.type == 3:
            result = client.read_holding_registers(args.register, args.count, **slave_kwarg)
        elif args.type == 4:
            result = client.read_input_registers(args.register, args.count, **slave_kwarg)
        else:
            print(f"Unsupported function code: {args.type}")
            sys.exit(1)

        if result.isError():
            print(f"Modbus error: {result}")
            sys.exit(1)

        print(f"Protocol configuration: Modbus TCP")
        print(f"Slave configuration...: address = [{args.address}]")
        print(f"Communication.........: {args.host}, port {args.port}, t/o 1.00 s, poll rate 1000 ms")
        type_name = {1: 'coil', 2: 'discrete', 3: 'holding', 4: 'input'}.get(args.type, 'unknown')
        print(f"Data type.............: 16-bit register, {type_name} register table")
        print()

        if hasattr(result, 'registers'):
            values = result.registers
        elif hasattr(result, 'bits'):
            values = [int(b) for b in result.bits[:args.count]]
        else:
            values = []

        for i, value in enumerate(values):
            print(f"[{args.register + i}]: {value}")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        client.close()

if __name__ == "__main__":
    main()