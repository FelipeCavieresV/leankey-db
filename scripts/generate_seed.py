"""Generate a deterministic schema and seed from the existing frontend report."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT.parent / 'leankey-front/src/data/ksec.json'
data = json.loads(source.read_text())
columns = json.loads((ROOT / 'scripts/columns.json').read_text())
def literal(value):
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"
schema = ['BEGIN;', '''CREATE TABLE IF NOT EXISTS reports (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 cutoff date NOT NULL UNIQUE, source text NOT NULL, executive_summary text NOT NULL,
 headers jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);''', '''CREATE TABLE IF NOT EXISTS requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 title text NOT NULL CHECK (length(trim(title)) > 0),
 company text NOT NULL CHECK (length(trim(company)) > 0),
 state text NOT NULL DEFAULT 'Pendiente' CHECK (state IN ('Pendiente','En revisión','Aprobado','Rechazado')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);''']
seed=['BEGIN;', 'INSERT INTO reports (cutoff,source,executive_summary,headers) VALUES (' + ','.join(literal(x) for x in [data['cutoff'],data['source'],data['executiveSummary'],json.dumps({k:v['headers'] for k,v in data['tables'].items()},ensure_ascii=False)]) + ') ON CONFLICT (cutoff) DO NOTHING;']
for name, cols in columns.items():
    rows=data['tables'][name]['rows']
    assert all(len(row)==len(cols) for row in rows)
    definitions=[]
    for i,col in enumerate(cols):
        numeric=all(isinstance(r[i],(int,float)) for r in rows)
        kind = ('double precision' if col == 'approval' else 'integer') if numeric else 'text'
        constraint = f' CHECK ("{col}" >= 0)' if numeric else ''
        if col == 'approval':
            constraint = f' CHECK ("{col}" BETWEEN 0 AND 1)'
        definitions.append(f'"{col}" {kind} NOT NULL{constraint}')
    schema.append(f'CREATE TABLE IF NOT EXISTS ksec_{name} (report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE, position integer NOT NULL CHECK (position >= 0), '+', '.join(definitions)+', PRIMARY KEY (report_id,position));')
    if 'contractor' in cols:
        schema.append(f'CREATE INDEX IF NOT EXISTS ksec_{name}_company ON ksec_{name}(report_id,contractor);')
    names=','.join('"'+c+'"' for c in cols)
    for i,row in enumerate(rows):
        seed.append(f'INSERT INTO ksec_{name} (report_id,position,{names}) SELECT id,{i},'+','.join(literal(x) for x in row)+f' FROM reports WHERE cutoff={literal(data["cutoff"])} ON CONFLICT (report_id,position) DO NOTHING;')
schema.append('COMMIT;');seed.append('COMMIT;')
(ROOT/'init/001_schema.sql').write_text('\n'.join(schema)+'\n')
(ROOT/'init/002_seed.sql').write_text('\n'.join(seed)+'\n')
print('Generated schema and seed:',sum(len(t['rows']) for t in data['tables'].values()),'rows')
