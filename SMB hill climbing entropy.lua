-- Super Mario Bros. AI shit

function text(x,y,str)
	if (x > 0 and x < 255 and y > 0 and y < 240) then
		gui.text(x,y,str);
	end;
end;

-- copy a table
function shallowcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- given the probability values, generate a move
function genKeys(pRight, pLeft, pRun, pJmp, pJmpHold, lastMove)
   local keys =  shallowcopy(lastMove)
   local dirProb = math.random()
   if dirProb < pRight then
      keys['left'] = false
      keys['right'] = true
   elseif dirProb < pRight + pLeft then
      keys['left'] = true
      keys['right'] = false
   else
      keys['left'] = false
      keys['right'] = false
   end

   if keys['A'] then
      keys['A'] = math.random() < pJmpHold
   else
      keys['A'] = math.random() < pJmp
   end

   keys['B'] = math.random() < pRun

   return keys
end

function genKeysEntropy(entropy, pRight, pLeft, pRun, pJmp, pJmpHold, lastMove)
   if math.random() > entropy then
      -- introduce a mutation
      trait = math.random
      if math.random() < 0.5 then
         -- 50% chance to mutate direction
         mutator = math.random()
         pRight = 0.8 * pRight + 0.2 * mutator
         pLeft = 0.8 * pLeft + 0.2 * mutator
      else
         -- 50% chance to mutate jmp
         mutator = math.random()
         pJmp = 0.8 * pJmp + 0.2 * mutator
      end
   end
   -- if entropy ~= 1 then
   --    -- for now just change the directions I guess
   --    pRight = pRight * (1 - (1 - entropy) * math.random())
   --    pLeft = (1 - pRight) * math.random()
   -- end
   return genKeys(pRight, pLeft, pRun, pJmp, pJmpHold, lastMove)
end


-- get player position
function getPos()
   return (memory.readbyte(0x006D) * 256) + memory.readbyte(0x0086)
end

function slidingFlag()
   return memory.readbyte(0x001D)==0x03
end

function dying()
   -- player dying or fell below the floor
   return memory.readbyte(0x000E) == 0x0B or memory.readbyte(0x00Ce) > 240
end

-- tell if we're in a situation where we can't control the player
function noControl()
   local state = memory.readbyte(0x000E)
   return state == 0x04 or state == 0x05 or state == 0x09 or state == 2 or state == 3
end

function victory()
   -- hack for the castle levels up to world 3
   local world = memory.readbyte(0x075F)
   if startLevel == 4 and (world == 0 or world == 1) then
      return getPos() >= 2280
   elseif startLevel == 3 and world == 2 then
      return getPos() >= 2280
   -- undefined for other castles
   else
      return slidingFlag()
   end
end


-- how many frames will take to generate new key
key_frames = 5
-- number of moves to backtrack (on the first backtrack)
initBacktrack = 20
backtrack = initBacktrack
maxBacktrack = 200
-- number of failed attempts before the backtrack range is increased
failsPerIteration = 10
-- after how much horizontal movement will we make a snapshot
blockWidth = 280
-- deadend detection
deMoves = 40
deThreshold = 10

-- 0 is complete entropy, 1 is no entropy
entropyFactor = 0.95

-- global probabilities
_pRight = 0.7
_pLeft = 0.1
_pRun = 0.0
_pJmp = 0.14
_pJmpHold = 0.8

-- the beginning of the current level
start = savestate.object(1)
savestate.save(start)

-- the beginning of the current block
block = savestate.object(2)
savestate.save(block)

-- initial information
startLevel = memory.readbyte(0x0760)
startLives = memory.readbyte(0x075A)
startPos = getPos()
-- the position of the last block save
blockPos = startPos
-- the maximum position reached
maxPos = startPos

-- the move history is a list of lists
moveHistory = {}
-- starting keys
moveHistory[0] = {}
moveHistory[0]['pos'] = startPos
moveHistory[0]['keys'] = joypad.get(1)
-- the index of the move after the last block save
blockMove = 1

emu.speedmode("turbo")

-- the index of the previous move in the block
moveNum = 1
-- whether we reached a new maximum on the current trial
trialMax = startPos
-- number of consecutive failed attempts to advance
fails = 0
-- entropy: the higher this is, the more random our outcomes become
entropy = 1

-- statistics for final output
startTime = os.time()
deaths = 0
moves = 0
while (true) do
   local level = memory.readbyte(0x0760)
   --if slidingFlag() or level ~= startLevel or getPos() > 2400 then
   if victory() then
      print("MADE IT!")
      break
   end

   while noControl() do
      emu.frameadvance()
   end

   -- get the next move (generate it if necessary
   local newMove = false
   if moveHistory[moveNum] == nil then
      keys = genKeysEntropy(entropy, _pRight, _pLeft, _pRun, _pJmp, _pJmpHold, moveHistory[moveNum-1]['keys'])
      moveHistory[moveNum] = {}
      moveHistory[moveNum]['keys'] = keys
      moveHistory[moveNum]['pos'] = getPos()
      newMove = true
   end
   -- play several frames with the move
   for i=1,key_frames,1 do
      joypad.set(1, moveHistory[moveNum]['keys'])
      emu.frameadvance()
   end


   -- check the position
   local pos = getPos()
   if pos > trialMax then
      trialMax = pos
   end

   -- see if we've uncovered a new block
   if maxPos - blockPos > blockWidth and maxPos - pos < blockWidth then
      print("Putting block at "..pos.."\n")
      blockPos = pos
      blockMove = moveNum + 1
      savestate.save(block)
   end

   -- see if we're stuck
   local movedEnough = true
   if moveNum > deMoves then
      movedEnough = trialMax - moveHistory[moveNum - deMoves]['pos']
         >= deThreshold
   end

   -- see if we've died
   local lives = memory.readbyte(0x075A)
   if lives < startLives or dying() or not movedEnough then
      if trialMax > maxPos then
         maxPos = trialMax
         fails = 0
         entropy = entropyFactor * entropy
         backtrack = initBacktrack
      else
         fails = fails + 1
         if fails >= failsPerIteration then
            fails = 0
            backtrack = backtrack + initBacktrack
         end
      end

      deaths = deaths + 1

      -- backtrack some number of moves
      local newStart = math.max(moveNum - backtrack, blockMove, 1)
      for i=newStart,moveNum,1 do
         if blockPos <= startPos
            or (moveHistory[i] ~= nil
                   and moveHistory[i]['pos'] > maxPos - blockWidth)
         then
            moveHistory[i] = nil
         end
      end

      trialMax = 0
      moveNum = blockMove - 1
      savestate.load(block)
   end

   moveNum = moveNum + 1
   moves = moves + 1
end

elapsed = os.time() - startTime
print('Found a solution in '..elapsed..' seconds.')
print('It took a total of '..moves..' moves and '..deaths..' deaths.')
print('The final solution is '..moveNum..' moves long.')

-- replay the solution at normal speed
emu.speedmode("normal")
moveNum = 1
savestate.load(start)
while moveHistory[moveNum] ~= nil do
   while noControl() do
      emu.frameadvance()
   end

   for i=1,key_frames,1 do
      joypad.set(1, moveHistory[moveNum]['keys'])
      emu.frameadvance()
   end
   moveNum = moveNum + 1
end
