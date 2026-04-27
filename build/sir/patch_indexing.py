from pathlib import Path


path = Path("/code/sir/indexing.py")
text = path.read_text()

old_imports = "import multiprocessing\nimport signal\n"
new_imports = "import multiprocessing\nimport os\nimport signal\n"
assert old_imports in text, "expected import block not found"
text = text.replace(old_imports, new_imports, 1)

old_reindex = "    _multiprocessed_import(entities)\n"
new_reindex = (
    '    if os.environ.get("SIR_FORCE_SERIAL_REINDEX") == "1" and len(entities) == 1:\n'
    "        _serial_import(entities)\n"
    "        return\n\n"
    "    _multiprocessed_import(entities)\n"
)
assert old_reindex in text, "expected reindex call not found"
text = text.replace(old_reindex, new_reindex, 1)

marker = "def _multiprocessed_import(entity_names, live=False, entities=None):\n"
insert = """class _SerialSolrQueue:\n    def __init__(self, solr_connection, batch_size):\n        self.solr_connection = solr_connection\n        self.batch_size = batch_size\n        self.data = []\n\n    def put(self, item):\n        if item is STOP:\n            return\n        self.data.append(item)\n        if len(self.data) >= self.batch_size:\n            send_data_to_solr(self.solr_connection, self.data)\n            self.data = []\n\n    def flush(self):\n        if self.data:\n            send_data_to_solr(self.solr_connection, self.data)\n            self.data = []\n        self.solr_connection.commit()\n\n\ndef _serial_import(entity_names, live=False, entities=None):\n    query_batch_size = config.CFG.getint("sir", "query_batch_size")\n    try:\n        importlimit = config.CFG.getint("sir", "importlimit")\n    except NoOptionError:\n        importlimit = 0\n\n    solr_batch_size = config.CFG.getint("solr", "batch_size")\n    db_session = util.db_session()\n\n    for e in entity_names:\n        logger.info("Importing %s serially...", e)\n        solr_connection = util.solr_connection(e)\n        data_queue = _SerialSolrQueue(solr_connection, solr_batch_size)\n\n        if live:\n            entity_id_list = list(entities.get(e, set())) if entities else []\n            for i in range(0, len(entity_id_list), query_batch_size):\n                session = Session(util.engine())\n                live_index_entity(session, e, entity_id_list[i:i + query_batch_size], data_queue)\n        else:\n            with util.db_session_ctx(db_session) as session:\n                for bounds in querying.iter_bounds(session, SCHEMA[e].model, query_batch_size, importlimit):\n                    if not PROCESS_FLAG.value:\n                        raise SIR_EXIT\n                    serial_session = Session(util.engine())\n                    index_entity(serial_session, e, bounds, data_queue)\n\n        data_queue.flush()\n\n\n"""
assert marker in text, "expected multiprocess marker not found"
text = text.replace(marker, insert + marker, 1)

path.write_text(text)
