-- PostgreSQL-incompatible datetime tests.

local t = require('luatest')
local dt = require('datetime')

local SUPPORTED_DATETIME_FORMATS = {
    ['ISO8601 ONLY'] = {
        -- Dates.
        {
            fmt = '%V-W%W-%w',
            buf = '2024-W31-3',
        }, {
            fmt = '%Y%O',
            buf = '2024213',
        }, {
            fmt = '%VW%W%w',
            buf = '2024W313',
        },
        -- Dates-Times.
        {
            fmt = '%Y-%M-%DT%h',
            buf = '2024-07-31T17',
        }, {
            fmt = '%Y-%M-%DT%,1h',
            buf = '2024-07-31T17,5',
        }, {
            fmt = '%Y-%M-%DT%.1h',
            buf = '2024-07-31T17.5',
        }, {
            fmt = '%Y-%M-%DT%h:%,1m',
            buf = '2024-07-31T17:30,0',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%,3s',
            buf = '2024-07-31T17:30:02,132',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%s,%u',
            buf = '2024-07-31T17:30:02,132209',
        }, {
            fmt = '%Y-%M-%DT%hZ',
            buf = '2024-07-31T14Z',
        }, {
            fmt = '%Y-%M-%DT%,1hZ',
            buf = '2024-07-31T14,5Z',
        }, {
            fmt = '%Y-%M-%DT%.1hZ',
            buf = '2024-07-31T14.5Z',
        }, {
            fmt = '%Y-%M-%DT%h:%,1mZ',
            buf = '2024-07-31T14:30,0Z',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%,3sZ',
            buf = '2024-07-31T14:30:02,132Z',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%s,%uZ',
            buf = '2024-07-31T14:30:02,132209Z',
        }, {
            fmt = '%Y-%M-%DT%h%Z',
            buf = '2024-07-31T17+03',
        }, {
            fmt = '%Y-%M-%DT%,1h%Z',
            buf = '2024-07-31T17,5+03',
        }, {
            fmt = '%Y-%M-%DT%.1h%Z',
            buf = '2024-07-31T17.5+03',
        }, {
            fmt = '%Y-%M-%DT%h:%,1m%Z',
            buf = '2024-07-31T17:30,0+03',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%,3s%Z',
            buf = '2024-07-31T17:30:02,132+03',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%s,%u%Z',
            buf = '2024-07-31T17:30:02,132209+03',
        }, {
            fmt = '%Y-%M-%DT%h%Z:%z',
            buf = '2024-07-31T17+03:00',
        }, {
            fmt = '%Y-%M-%DT%,1h%Z:%z',
            buf = '2024-07-31T17,5+03:00',
        }, {
            fmt = '%Y-%M-%DT%.1h%Z:%z',
            buf = '2024-07-31T17.5+03:00',
        }, {
            fmt = '%Y-%M-%DT%h:%,1m%Z:%z',
            buf = '2024-07-31T17:30,0+03:00',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%,3s%Z:%z',
            buf = '2024-07-31T17:30:02,132+03:00',
        }, {
            fmt = '%Y-%M-%DT%h:%m:%s,%u%Z:%z',
            buf = '2024-07-31T17:30:02,132209+03:00',
        }, {
            fmt = '%V-W%W-%wT%h',
            buf = '2024-W31-3T17',
        }, {
            fmt = '%V-W%W-%wT%,1h',
            buf = '2024-W31-3T17,5',
        }, {
            fmt = '%V-W%W-%wT%.1h',
            buf = '2024-W31-3T17.5',
        }, {
            fmt = '%V-W%W-%wT%h:%m',
            buf = '2024-W31-3T17:30',
        }, {
            fmt = '%V-W%W-%wT%h:%,1m',
            buf = '2024-W31-3T17:30,0',
        }, {
            fmt = '%V-W%W-%wT%h:%.1m',
            buf = '2024-W31-3T17:30.0',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s',
            buf = '2024-W31-3T17:30:02',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.1s',
            buf = '2024-W31-3T17:30:02.1',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.2s',
            buf = '2024-W31-3T17:30:02.13',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%,3s',
            buf = '2024-W31-3T17:30:02,132',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.3s',
            buf = '2024-W31-3T17:30:02.132',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s,%u',
            buf = '2024-W31-3T17:30:02,132209',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s.%u',
            buf = '2024-W31-3T17:30:02.132209',
        }, {
            fmt = '%V-W%W-%wT%hZ',
            buf = '2024-W31-3T14Z',
        }, {
            fmt = '%V-W%W-%wT%,1hZ',
            buf = '2024-W31-3T14,5Z',
        }, {
            fmt = '%V-W%W-%wT%.1hZ',
            buf = '2024-W31-3T14.5Z',
        }, {
            fmt = '%V-W%W-%wT%h:%mZ',
            buf = '2024-W31-3T14:30Z',
        }, {
            fmt = '%V-W%W-%wT%h:%,1mZ',
            buf = '2024-W31-3T14:30,0Z',
        }, {
            fmt = '%V-W%W-%wT%h:%.1mZ',
            buf = '2024-W31-3T14:30.0Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%sZ',
            buf = '2024-W31-3T14:30:02Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.1sZ',
            buf = '2024-W31-3T14:30:02.1Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.2sZ',
            buf = '2024-W31-3T14:30:02.13Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%,3sZ',
            buf = '2024-W31-3T14:30:02,132Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.3sZ',
            buf = '2024-W31-3T14:30:02.132Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s,%uZ',
            buf = '2024-W31-3T14:30:02,132209Z',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s.%uZ',
            buf = '2024-W31-3T14:30:02.132209Z',
        }, {
            fmt = '%V-W%W-%wT%h%Z',
            buf = '2024-W31-3T17+03',
        }, {
            fmt = '%V-W%W-%wT%,1h%Z',
            buf = '2024-W31-3T17,5+03',
        }, {
            fmt = '%V-W%W-%wT%.1h%Z',
            buf = '2024-W31-3T17.5+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m%Z',
            buf = '2024-W31-3T17:30+03',
        }, {
            fmt = '%V-W%W-%wT%h:%,1m%Z',
            buf = '2024-W31-3T17:30,0+03',
        }, {
            fmt = '%V-W%W-%wT%h:%.1m%Z',
            buf = '2024-W31-3T17:30.0+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s%Z',
            buf = '2024-W31-3T17:30:02+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.1s%Z',
            buf = '2024-W31-3T17:30:02.1+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.2s%Z',
            buf = '2024-W31-3T17:30:02.13+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%,3s%Z',
            buf = '2024-W31-3T17:30:02,132+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.3s%Z',
            buf = '2024-W31-3T17:30:02.132+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s,%u%Z',
            buf = '2024-W31-3T17:30:02,132209+03',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s.%u%Z',
            buf = '2024-W31-3T17:30:02.132209+03',
        }, {
            fmt = '%V-W%W-%wT%h%Z:%z',
            buf = '2024-W31-3T17+03:00',
        }, {
            fmt = '%V-W%W-%wT%,1h%Z:%z',
            buf = '2024-W31-3T17,5+03:00',
        }, {
            fmt = '%V-W%W-%wT%.1h%Z:%z',
            buf = '2024-W31-3T17.5+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m%Z:%z',
            buf = '2024-W31-3T17:30+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%,1m%Z:%z',
            buf = '2024-W31-3T17:30,0+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%.1m%Z:%z',
            buf = '2024-W31-3T17:30.0+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s%Z:%z',
            buf = '2024-W31-3T17:30:02+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.1s%Z:%z',
            buf = '2024-W31-3T17:30:02.1+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.2s%Z:%z',
            buf = '2024-W31-3T17:30:02.13+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%,3s%Z:%z',
            buf = '2024-W31-3T17:30:02,132+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%.3s%Z:%z',
            buf = '2024-W31-3T17:30:02.132+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s,%u%Z:%z',
            buf = '2024-W31-3T17:30:02,132209+03:00',
        }, {
            fmt = '%V-W%W-%wT%h:%m:%s.%u%Z:%z',
            buf = '2024-W31-3T17:30:02.132209+03:00',
        }, {
            fmt = '%Y-%OT%h',
            buf = '2024-213T17',
        }, {
            fmt = '%Y-%OT%,1h',
            buf = '2024-213T17,5',
        }, {
            fmt = '%Y-%OT%.1h',
            buf = '2024-213T17.5',
        }, {
            fmt = '%Y-%OT%h:%,1m',
            buf = '2024-213T17:30,0',
        }, {
            fmt = '%Y-%OT%h:%m:%,3s',
            buf = '2024-213T17:30:02,132',
        }, {
            fmt = '%Y-%OT%h:%m:%s,%u',
            buf = '2024-213T17:30:02,132209',
        }, {
            fmt = '%Y-%OT%hZ',
            buf = '2024-213T14Z',
        }, {
            fmt = '%Y-%OT%,1hZ',
            buf = '2024-213T14,5Z',
        }, {
            fmt = '%Y-%OT%.1hZ',
            buf = '2024-213T14.5Z',
        }, {
            fmt = '%Y-%OT%h:%,1mZ',
            buf = '2024-213T14:30,0Z',
        }, {
            fmt = '%Y-%OT%h:%m:%,3sZ',
            buf = '2024-213T14:30:02,132Z',
        }, {
            fmt = '%Y-%OT%h:%m:%s,%uZ',
            buf = '2024-213T14:30:02,132209Z',
        }, {
            fmt = '%Y-%OT%h%Z',
            buf = '2024-213T17+03',
        }, {
            fmt = '%Y-%OT%,1h%Z',
            buf = '2024-213T17,5+03',
        }, {
            fmt = '%Y-%OT%.1h%Z',
            buf = '2024-213T17.5+03',
        }, {
            fmt = '%Y-%OT%h:%,1m%Z',
            buf = '2024-213T17:30,0+03',
        }, {
            fmt = '%Y-%OT%h:%m:%,3s%Z',
            buf = '2024-213T17:30:02,132+03',
        }, {
            fmt = '%Y-%OT%h:%m:%s,%u%Z',
            buf = '2024-213T17:30:02,132209+03',
        }, {
            fmt = '%Y-%OT%h%Z:%z',
            buf = '2024-213T17+03:00',
        }, {
            fmt = '%Y-%OT%,1h%Z:%z',
            buf = '2024-213T17,5+03:00',
        }, {
            fmt = '%Y-%OT%.1h%Z:%z',
            buf = '2024-213T17.5+03:00',
        }, {
            fmt = '%Y-%OT%h:%,1m%Z:%z',
            buf = '2024-213T17:30,0+03:00',
        }, {
            fmt = '%Y-%OT%h:%m:%,3s%Z:%z',
            buf = '2024-213T17:30:02,132+03:00',
        }, {
            fmt = '%Y-%OT%h:%m:%s,%u%Z:%z',
            buf = '2024-213T17:30:02,132209+03:00',
        }, {
            fmt = '%Y%M%DT%h',
            buf = '20240731T17',
        }, {
            fmt = '%Y%M%DT%,1h',
            buf = '20240731T17,5',
        }, {
            fmt = '%Y%M%DT%.1h',
            buf = '20240731T17.5',
        }, {
            fmt = '%Y%M%DT%h%,1m',
            buf = '20240731T1730,0',
        }, {
            fmt = '%Y%M%DT%h%m%,3s',
            buf = '20240731T173002,132',
        }, {
            fmt = '%Y%M%DT%h%m%s,%u',
            buf = '20240731T173002,132209',
        }, {
            fmt = '%Y%M%DT%hZ',
            buf = '20240731T14Z',
        }, {
            fmt = '%Y%M%DT%,1hZ',
            buf = '20240731T14,5Z',
        }, {
            fmt = '%Y%M%DT%.1hZ',
            buf = '20240731T14.5Z',
        }, {
            fmt = '%Y%M%DT%h%,1mZ',
            buf = '20240731T1430,0Z',
        }, {
            fmt = '%Y%M%DT%h%m%,3sZ',
            buf = '20240731T143002,132Z',
        }, {
            fmt = '%Y%M%DT%h%m%s,%uZ',
            buf = '20240731T143002,132209Z',
        }, {
            fmt = '%Y%M%DT%h%Z',
            buf = '20240731T17+03',
        }, {
            fmt = '%Y%M%DT%,1h%Z',
            buf = '20240731T17,5+03',
        }, {
            fmt = '%Y%M%DT%.1h%Z',
            buf = '20240731T17.5+03',
        }, {
            fmt = '%Y%M%DT%h%,1m%Z',
            buf = '20240731T1730,0+03',
        }, {
            fmt = '%Y%M%DT%h%m%,3s%Z',
            buf = '20240731T173002,132+03',
        }, {
            fmt = '%Y%M%DT%h%m%s,%u%Z',
            buf = '20240731T173002,132209+03',
        }, {
            fmt = '%Y%M%DT%h%Z%z',
            buf = '20240731T17+0300',
        }, {
            fmt = '%Y%M%DT%,1h%Z%z',
            buf = '20240731T17,5+0300',
        }, {
            fmt = '%Y%M%DT%.1h%Z%z',
            buf = '20240731T17.5+0300',
        }, {
            fmt = '%Y%M%DT%h%,1m%Z%z',
            buf = '20240731T1730,0+0300',
        }, {
            fmt = '%Y%M%DT%h%m%,3s%Z%z',
            buf = '20240731T173002,132+0300',
        }, {
            fmt = '%Y%M%DT%h%m%s,%u%Z%z',
            buf = '20240731T173002,132209+0300',
        }, {
            fmt = '%VW%W%wT%h',
            buf = '2024W313T17',
        }, {
            fmt = '%VW%W%wT%,1h',
            buf = '2024W313T17,5',
        }, {
            fmt = '%VW%W%wT%.1h',
            buf = '2024W313T17.5',
        }, {
            fmt = '%VW%W%wT%h%m',
            buf = '2024W313T1730',
        }, {
            fmt = '%VW%W%wT%h%,1m',
            buf = '2024W313T1730,0',
        }, {
            fmt = '%VW%W%wT%h%.1m',
            buf = '2024W313T1730.0',
        }, {
            fmt = '%VW%W%wT%h%m%s',
            buf = '2024W313T173002',
        }, {
            fmt = '%VW%W%wT%h%m%.1s',
            buf = '2024W313T173002.1',
        }, {
            fmt = '%VW%W%wT%h%m%.2s',
            buf = '2024W313T173002.13',
        }, {
            fmt = '%VW%W%wT%h%m%,3s',
            buf = '2024W313T173002,132',
        }, {
            fmt = '%VW%W%wT%h%m%.3s',
            buf = '2024W313T173002.132',
        }, {
            fmt = '%VW%W%wT%h%m%s,%u',
            buf = '2024W313T173002,132209',
        }, {
            fmt = '%VW%W%wT%h%m%s.%u',
            buf = '2024W313T173002.132209',
        }, {
            fmt = '%VW%W%wT%hZ',
            buf = '2024W313T14Z',
        }, {
            fmt = '%VW%W%wT%,1hZ',
            buf = '2024W313T14,5Z',
        }, {
            fmt = '%VW%W%wT%.1hZ',
            buf = '2024W313T14.5Z',
        }, {
            fmt = '%VW%W%wT%h%mZ',
            buf = '2024W313T1430Z',
        }, {
            fmt = '%VW%W%wT%h%,1mZ',
            buf = '2024W313T1430,0Z',
        }, {
            fmt = '%VW%W%wT%h%.1mZ',
            buf = '2024W313T1430.0Z',
        }, {
            fmt = '%VW%W%wT%h%m%sZ',
            buf = '2024W313T143002Z',
        }, {
            fmt = '%VW%W%wT%h%m%.1sZ',
            buf = '2024W313T143002.1Z',
        }, {
            fmt = '%VW%W%wT%h%m%.2sZ',
            buf = '2024W313T143002.13Z',
        }, {
            fmt = '%VW%W%wT%h%m%,3sZ',
            buf = '2024W313T143002,132Z',
        }, {
            fmt = '%VW%W%wT%h%m%.3sZ',
            buf = '2024W313T143002.132Z',
        }, {
            fmt = '%VW%W%wT%h%m%s,%uZ',
            buf = '2024W313T143002,132209Z',
        }, {
            fmt = '%VW%W%wT%h%m%s.%uZ',
            buf = '2024W313T143002.132209Z',
        }, {
            fmt = '%VW%W%wT%h%Z',
            buf = '2024W313T17+03',
        }, {
            fmt = '%VW%W%wT%,1h%Z',
            buf = '2024W313T17,5+03',
        }, {
            fmt = '%VW%W%wT%.1h%Z',
            buf = '2024W313T17.5+03',
        }, {
            fmt = '%VW%W%wT%h%m%Z',
            buf = '2024W313T1730+03',
        }, {
            fmt = '%VW%W%wT%h%,1m%Z',
            buf = '2024W313T1730,0+03',
        }, {
            fmt = '%VW%W%wT%h%.1m%Z',
            buf = '2024W313T1730.0+03',
        }, {
            fmt = '%VW%W%wT%h%m%s%Z',
            buf = '2024W313T173002+03',
        }, {
            fmt = '%VW%W%wT%h%m%.1s%Z',
            buf = '2024W313T173002.1+03',
        }, {
            fmt = '%VW%W%wT%h%m%.2s%Z',
            buf = '2024W313T173002.13+03',
        }, {
            fmt = '%VW%W%wT%h%m%,3s%Z',
            buf = '2024W313T173002,132+03',
        }, {
            fmt = '%VW%W%wT%h%m%.3s%Z',
            buf = '2024W313T173002.132+03',
        }, {
            fmt = '%VW%W%wT%h%m%s,%u%Z',
            buf = '2024W313T173002,132209+03',
        }, {
            fmt = '%VW%W%wT%h%m%s.%u%Z',
            buf = '2024W313T173002.132209+03',
        }, {
            fmt = '%VW%W%wT%h%Z%z',
            buf = '2024W313T17+0300',
        }, {
            fmt = '%VW%W%wT%,1h%Z%z',
            buf = '2024W313T17,5+0300',
        }, {
            fmt = '%VW%W%wT%.1h%Z%z',
            buf = '2024W313T17.5+0300',
        }, {
            fmt = '%VW%W%wT%h%m%Z%z',
            buf = '2024W313T1730+0300',
        }, {
            fmt = '%VW%W%wT%h%,1m%Z%z',
            buf = '2024W313T1730,0+0300',
        }, {
            fmt = '%VW%W%wT%h%.1m%Z%z',
            buf = '2024W313T1730.0+0300',
        }, {
            fmt = '%VW%W%wT%h%m%s%Z%z',
            buf = '2024W313T173002+0300',
        }, {
            fmt = '%VW%W%wT%h%m%.1s%Z%z',
            buf = '2024W313T173002.1+0300',
        }, {
            fmt = '%VW%W%wT%h%m%.2s%Z%z',
            buf = '2024W313T173002.13+0300',
        }, {
            fmt = '%VW%W%wT%h%m%,3s%Z%z',
            buf = '2024W313T173002,132+0300',
        }, {
            fmt = '%VW%W%wT%h%m%.3s%Z%z',
            buf = '2024W313T173002.132+0300',
        }, {
            fmt = '%VW%W%wT%h%m%s,%u%Z%z',
            buf = '2024W313T173002,132209+0300',
        }, {
            fmt = '%VW%W%wT%h%m%s.%u%Z%z',
            buf = '2024W313T173002.132209+0300',
        }, {
            fmt = '%Y%OT%h',
            buf = '2024213T17',
        }, {
            fmt = '%Y%OT%,1h',
            buf = '2024213T17,5',
        }, {
            fmt = '%Y%OT%.1h',
            buf = '2024213T17.5',
        }, {
            fmt = '%Y%OT%h%m',
            buf = '2024213T1730',
        }, {
            fmt = '%Y%OT%h%,1m',
            buf = '2024213T1730,0',
        }, {
            fmt = '%Y%OT%h%.1m',
            buf = '2024213T1730.0',
        }, {
            fmt = '%Y%OT%h%m%s',
            buf = '2024213T173002',
        }, {
            fmt = '%Y%OT%h%m%.1s',
            buf = '2024213T173002.1',
        }, {
            fmt = '%Y%OT%h%m%.2s',
            buf = '2024213T173002.13',
        }, {
            fmt = '%Y%OT%h%m%,3s',
            buf = '2024213T173002,132',
        }, {
            fmt = '%Y%OT%h%m%.3s',
            buf = '2024213T173002.132',
        }, {
            fmt = '%Y%OT%h%m%s,%u',
            buf = '2024213T173002,132209',
        }, {
            fmt = '%Y%OT%h%m%s.%u',
            buf = '2024213T173002.132209',
        }, {
            fmt = '%Y%OT%hZ',
            buf = '2024213T14Z',
        }, {
            fmt = '%Y%OT%,1hZ',
            buf = '2024213T14,5Z',
        }, {
            fmt = '%Y%OT%.1hZ',
            buf = '2024213T14.5Z',
        }, {
            fmt = '%Y%OT%h%mZ',
            buf = '2024213T1430Z',
        }, {
            fmt = '%Y%OT%h%,1mZ',
            buf = '2024213T1430,0Z',
        }, {
            fmt = '%Y%OT%h%.1mZ',
            buf = '2024213T1430.0Z',
        }, {
            fmt = '%Y%OT%h%m%sZ',
            buf = '2024213T143002Z',
        }, {
            fmt = '%Y%OT%h%m%.1sZ',
            buf = '2024213T143002.1Z',
        }, {
            fmt = '%Y%OT%h%m%.2sZ',
            buf = '2024213T143002.13Z',
        }, {
            fmt = '%Y%OT%h%m%,3sZ',
            buf = '2024213T143002,132Z',
        }, {
            fmt = '%Y%OT%h%m%.3sZ',
            buf = '2024213T143002.132Z',
        }, {
            fmt = '%Y%OT%h%m%s,%uZ',
            buf = '2024213T143002,132209Z',
        }, {
            fmt = '%Y%OT%h%m%s.%uZ',
            buf = '2024213T143002.132209Z',
        }, {
            fmt = '%Y%OT%h%Z',
            buf = '2024213T17+03',
        }, {
            fmt = '%Y%OT%,1h%Z',
            buf = '2024213T17,5+03',
        }, {
            fmt = '%Y%OT%.1h%Z',
            buf = '2024213T17.5+03',
        }, {
            fmt = '%Y%OT%h%m%Z',
            buf = '2024213T1730+03',
        }, {
            fmt = '%Y%OT%h%,1m%Z',
            buf = '2024213T1730,0+03',
        }, {
            fmt = '%Y%OT%h%.1m%Z',
            buf = '2024213T1730.0+03',
        }, {
            fmt = '%Y%OT%h%m%s%Z',
            buf = '2024213T173002+03',
        }, {
            fmt = '%Y%OT%h%m%.1s%Z',
            buf = '2024213T173002.1+03',
        }, {
            fmt = '%Y%OT%h%m%.2s%Z',
            buf = '2024213T173002.13+03',
        }, {
            fmt = '%Y%OT%h%m%,3s%Z',
            buf = '2024213T173002,132+03',
        }, {
            fmt = '%Y%OT%h%m%.3s%Z',
            buf = '2024213T173002.132+03',
        }, {
            fmt = '%Y%OT%h%m%s,%u%Z',
            buf = '2024213T173002,132209+03',
        }, {
            fmt = '%Y%OT%h%m%s.%u%Z',
            buf = '2024213T173002.132209+03',
        }, {
            fmt = '%Y%OT%h%Z%z',
            buf = '2024213T17+0300',
        }, {
            fmt = '%Y%OT%,1h%Z%z',
            buf = '2024213T17,5+0300',
        }, {
            fmt = '%Y%OT%.1h%Z%z',
            buf = '2024213T17.5+0300',
        }, {
            fmt = '%Y%OT%h%m%Z%z',
            buf = '2024213T1730+0300',
        }, {
            fmt = '%Y%OT%h%,1m%Z%z',
            buf = '2024213T1730,0+0300',
        }, {
            fmt = '%Y%OT%h%.1m%Z%z',
            buf = '2024213T1730.0+0300',
        }, {
            fmt = '%Y%OT%h%m%s%Z%z',
            buf = '2024213T173002+0300',
        }, {
            fmt = '%Y%OT%h%m%.1s%Z%z',
            buf = '2024213T173002.1+0300',
        }, {
            fmt = '%Y%OT%h%m%.2s%Z%z',
            buf = '2024213T173002.13+0300',
        }, {
            fmt = '%Y%OT%h%m%,3s%Z%z',
            buf = '2024213T173002,132+0300',
        }, {
            fmt = '%Y%OT%h%m%.3s%Z%z',
            buf = '2024213T173002.132+0300',
        }, {
            fmt = '%Y%OT%h%m%s,%u%Z%z',
            buf = '2024213T173002,132209+0300',
        }, {
            fmt = '%Y%OT%h%m%s.%u%Z%z',
            buf = '2024213T173002.132209+0300',
        }, {
            fmt = '%Y-%M-%DT%h-12',
            buf = '2024-07-31T02-12',
        }, {
            fmt = '%Y-%M-%DT%h-12:00',
            buf = '2024-07-31T02-12:00',
        },
    },
}

local UNSUPPORTED_DATETIME_FORMATS = {
    ['RFC3339 ONLY'] = {
        -- Dates-Times.
        {
            fmt = '%Y-%M-%D_%h:%m:%sZ',
            buf = '2024-07-31_14:30:02Z',
        }, {
            fmt = '%Y-%M-%D_%h:%m:%sz',
            buf = '2024-07-31_14:30:02z',
        }, {
            fmt = '%Y-%M-%D_%h:%m:%.3sZ',
            buf = '2024-07-31_14:30:02.132Z',
        }, {
            fmt = '%Y-%M-%D_%h:%m:%s.%uZ',
            buf = '2024-07-31_14:30:02.132209Z',
        }, {
            fmt = '%Y-%M-%D_%h:%m:%.3sz',
            buf = '2024-07-31_14:30:02.132z',
        }, {
            fmt = '%Y-%M-%D_%h:%m:%s.%uz',
            buf = '2024-07-31_14:30:02.132209z',
        },
    },

    ['ISO8601 ONLY'] = {
        -- Times.
        {
            fmt = '%h%m%.3s',
            buf = '155543.132',
        }, {
            fmt = '%h%m%.3sZ',
            buf = '125543.132Z',
        }, {
            fmt = '%h%m%.3s%Z',
            buf = '155543.132+03',
        }, {
            fmt = '%h%m%.3s%Z%z',
            buf = '155543.132+0300',
        },
        -- Ranges.
        {
            fmt = '%Y-%M-%D/P1Y',
            buf = '2024-07-31/P1Y',
        }, {
            fmt = '%Y-%M-%D/P1M',
            buf = '2024-07-31/P1M',
        }, {
            fmt = '%Y-%M-%D/P1D',
            buf = '2024-07-31/P1D',
        }, {
            fmt = '%Y-%O/P1Y',
            buf = '2024-213/P1Y',
        }, {
            fmt = '%Y-%O/P1M',
            buf = '2024-213/P1M',
        }, {
            fmt = '%Y-%O/P1D',
            buf = '2024-213/P1D',
        }, {
            fmt = '%Y-%M-%D/%Y-%O',
            buf = '2024-07-31/2024-213',
        }, {
            fmt = '%Y-%O/%Y-%O',
            buf = '2024-213/2024-213',
        },
    },
}

local pg = t.group('pgroup')

-- XXX: It is not possible to use parameterization by passing a
-- table with test parameters to `t.group` because datetime format
-- strings in test parameters contains the symbol `/` that is not
-- allowed in testcases names. The source code below inserts
-- test functions into a test group with testnames where `/` is
-- replaced with `_`.
for supported_by, standard_cases in pairs(SUPPORTED_DATETIME_FORMATS) do
    for _, case in ipairs(standard_cases) do
        local f = case.fmt
        local testcase_name = 'test_supported_format_' .. f:gsub('/', '_')
        local fmtmsg = "Format '%s' supported by %s not parsed by %s"

        if supported_by == 'RFC3339 AND ISO8601' then
            local buf = case.buf

            pg[testcase_name] = function()
                local iso8601_ok, iso8601_val = pcall(dt.parse, buf,
                                                      {format = 'iso8601'})
                local rfc3339_ok, rfc3339_val = pcall(dt.parse, buf,
                                                      {format = 'rfc3339'})
                t.assert(iso8601_ok, fmtmsg:format(f, supported_by, 'iso8601'))
                t.assert(rfc3339_ok, fmtmsg:format(f, supported_by, 'rfc3339'))
                t.assert_equals(iso8601_val, rfc3339_val, 'unequal results')
            end
        else
            local dtfmt = supported_by:gsub(' ONLY', ''):lower()
            pg[testcase_name] = function()
                local ok, _ = pcall(dt.parse, case.buf, {format = dtfmt})
                t.assert(ok, fmtmsg:format(f, supported_by, dtfmt))
            end
        end
    end
end

for supported_by, standard_cases in pairs(UNSUPPORTED_DATETIME_FORMATS) do
    for _, case in ipairs(standard_cases) do
        local f = case.fmt
        local testcase_name = 'test_unsupported_format_' .. f:gsub('/', '_')
        local fmtmsg = "Unsupported by Tarantool format '%s' " ..
                       "supported by %s is parsed by %s"

        if supported_by == 'RFC3339 AND ISO8601' then
            local buf = case.buf
            pg[testcase_name] = function()
                local iso8601_ok, _ = pcall(dt.parse, buf, {format = 'iso8601'})
                local rfc3339_ok, _ = pcall(dt.parse, buf, {format = 'rfc3339'})
                t.assert(not iso8601_ok, fmtmsg:format(f, supported_by,
                                                       'iso8601'))
                t.assert(not rfc3339_ok, fmtmsg:format(f, supported_by,
                                                       'rfc3339'))
            end
        else
            local dtfmt = supported_by:gsub(' ONLY', ''):lower()
            pg[testcase_name] = function()
                local ok, _ = pcall(dt.parse, case.buf, {format = dtfmt})
                t.assert(not ok, fmtmsg:format(f, supported_by, dtfmt))
            end
        end
    end
end
