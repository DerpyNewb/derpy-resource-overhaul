"""Check actual settlement-row labels against the generated service definitions."""
from pathlib import Path
import subprocess
import tempfile

import gen_mr_ui as ui
import gen_resource_overhaul as goods


def check():
    source=Path(ui.ROOT,'Modding Files/source/resource_overhaul/stores_panel.lua').read_text()
    start=source.index('S.BUNDLE_ICONS = ')   # the labels come from S.economy_cells, above economy_rows
    end=source.index("\n-- A SHIPMENT'S ESCORT",start)
    definitions=goods.economy_definitions()
    expected={'halls':'+2 control','records':'+5 growth','tea':'+2 control',
        'feasts':'+2 control','archives':'+5 growth','mess':'+2 control',
        'builders':'-5% cost','hospital':'+3% healing'}
    assert set(expected)==set(goods.SERVICES),'Add the new service to the label check'
    states=[dict(key=k,definition=definitions[k],on=True,paid=True,open=True) for k in sorted(expected)]
    code='local states='+ui._lua(states)+'\n'
    code+='S={ask=function() return states end,section=function(s) return s end,num=tostring,name=function(s) return s end,join=table.concat}\n'
    # S.T with no loc: the English, its {n} filled in (stores_panel.lua's own S.T)
    code+='function S.T(t,...) local a={...}; return (string.gsub(t,"{(%d+)}",function(i) return tostring(a[tonumber(i)]) end)) end\n'
    code+=source[start:end]
    code+='\nlocal v={rows={}}; S.economy_rows(v,{}, {name=function() return "test_region" end})\n'
    code+='for _,r in ipairs(v.rows) do if r.economy then print(r.economy.."|"..r[4]) end end\n'
    with tempfile.TemporaryDirectory() as folder:
        path=Path(folder,'probe.lua')
        path.write_text(code)
        result=subprocess.run([ui.LUA_EXE,str(path)],capture_output=True,text=True,check=True)
    actual=dict(line.split('|',1) for line in result.stdout.splitlines())
    assert actual==expected,(actual,expected)
    width=ui.L['VIEWS']['focus'][3][1]
    assert all(len(label)*ui.CHAR_W<=width for label in actual.values()),actual
    print('service labels: all eight effects/signs correct; fit the benefit column')


if __name__=='__main__':
    check()
