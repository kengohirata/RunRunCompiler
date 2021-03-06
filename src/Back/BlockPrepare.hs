module Back.BlockPrepare where

import           Back.Block
import           Back.BlockGraph
import           Control.Monad.State
import           Data.Graph
import           Data.Map
import           RunRun.RunRun
import           RunRun.Type         ()

prepare :: RunRun (Map String FunctionData)
prepare = do
    eputstrln "blockprepare ..."
    blockmaplist <- blockmap <$> get
    -- let newmap = mapWithKey (\(func, ys, zs, t) a ->
    --         FunctionData {blocks = a,
    --                      blockgraph = mkBlockGraph a,
    --                      line = (topSort . mkBlockGraphSeq) a,
    --                      args = ys, fargs = zs, ret = t
    --                      }) m
    let newlist = Prelude.map (\(((func, ys, zs, t), list), a) ->
            let g = mkBlockGraph a in
            (func,
            FunctionData {blocks = a,
                         blockGraph = g,
                         blockReverseGraph = transposeG g,
                         line = list,
                         args = ys, fargs = zs, ret = t, allStack = []
                         })) blockmaplist
    return $ fromList newlist



-- data FunctionData = FunctionData {
--                   blocks :: Map Int Block,
--                   blockgraph :: Graph,
--                   line :: [Int],
--                   args :: ![String],
--                   fargs :: ![String],
--                   ret :: !Type
--                   }
