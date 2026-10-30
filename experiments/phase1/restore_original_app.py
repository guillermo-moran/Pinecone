"""Execute the parent's one-shot, restore-only Simulator launch grant."""
import os
from pathlib import Path
import sys
import time
import measure


def main():
    output = Path(sys.argv[1]).resolve()
    flags = {
        'SIMCTL_CHILD_PINECONE_THREADED_PROTOTYPE': '0',
        'SIMCTL_CHILD_PINECONE_THREADED_MEMORY': '0',
        'SIMCTL_CHILD_PINECONE_VCPU_COUNT': '2',
        'SIMCTL_CHILD_PINECONE_EXPERIMENTAL_PARALLEL_VCPU': '1',
        'SIMCTL_CHILD_PINECONE_SIMULATOR_AUTORUN_COMMAND': 'start-pinecone-phosh &',
        'SIMCTL_CHILD_PINECONE_SIMULATOR_SHOW_DISPLAY': '1',
        'SIMCTL_CHILD_PINECONE_SIMULATOR_WRITE_PERFORMANCE_METRICS': '1',
        'SIMCTL_CHILD_PINECONE_SIMULATOR_DUMP_UART': '1',
    }
    command = ['xcrun', 'simctl', 'launch', '541E22EE-C52B-4478-A041-56FEDC23ACFF', 'me.gmoran.pinecone']
    result = measure.invoke(command, env={**os.environ, **flags})
    measure.write_json(output / 'app-restoration.json', {**result, 'flags': flags, 'utc': time.time(),
                       'scope': 'launch existing app only; no install, reset, image or default changes'})
    print(result)
    if result['returncode']:
        sys.exit(result['returncode'])


if __name__ == '__main__':
    main()
