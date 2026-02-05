# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# CELL ********************

# Welcome to your new notebook # test3
# Type here in the cell editor to add code!
import os, platform
from datetime import datetime, timezone

print("Fabric Git smoke test ✅")
print("UTC now:", datetime.now(timezone.utc).isoformat())
print("Python:", platform.python_version())
print("Platform:", platform.platform())
print("Sample env var keys:", sorted(list(os.environ.keys()))[:10])


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
