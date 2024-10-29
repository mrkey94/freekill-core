-- SPDX-License-Identifier: GPL-3.0-or-later

--[[
  关于SmartAI: 一款参考神杀基本AI架构的AI体系。
  该文件加载了AI常用的种种表以及实用函数等，并提供了可供拓展自定义AI逻辑的接口。

  AI的核心在于编程实现对各种交互的回应(或者说应付各种room:askForXXX)，
  所以本文件的直接目的是编写出合适的函数充实smart_cb表以实现合理的答复，
  但为了实现这个目的就还要去额外实现敌友判断、收益计算等等功能。
  为了便于各个拓展快速编写AI，还要封装一些AI判断时常用的函数。

  本文件包含以下内容：
  1. 基本策略代码：定义各种全局表，以及smart_cb表
  2. 敌我相关代码：关于如何判断敌我以及更新意向值等
  3. 十分常用的各种函数（？）

  -- TODO: 优化底层逻辑，防止AI每次操作之前都要json.decode一下。
  -- TODO: 更加详细的文档
--]]

---@class SmartAI: TrustAI
---@field private _memory table<string, any> @ AI底层的空间换时间机制
---@field public friends ServerPlayer[] @ 队友
---@field public enemies ServerPlayer[] @ 敌人
local SmartAI = TrustAI:subclass("SmartAI") -- 哦，我懒得写出闪之类的，不得不继承一下，饶了我吧

function SmartAI:initialize(player)
  TrustAI.initialize(self, player)
end

function SmartAI:makeReply()
  self._memory = {}
  return TrustAI.makeReply(self)
end

function SmartAI:__index(k)
  if self._memory[k] then
    return self._memory[k]
  end
  local ret
  if k == "enemies" then
    ret = table.filter(self.room.alive_players, function(p)
      return self:isEnemy(p)
    end)
  elseif k == "friends" then
    ret = table.filter(self.room.alive_players, function(p)
      return self:isFriend(p)
    end)
  end
  self._memory[k] = ret
  return ret
end

-- 面板相关交互：对应操控手牌区、技能面板、直接选择目标的交互
-- 对应UI中的"responding"状态和"playing"状态
-- AI代码需要像实际操作UI那样完成以下几个任务：
--   * 点击技能按钮，完成interaction与子卡选择；或者直接点可用手牌
--   * 选择目标
--   * 点确定
--===================================================

--- 主动技/视为技在SmartAI中几个选牌选目标的函数
---@class SmartAISkillSpec
---@field will_use? fun(skill: ActiveSkill, ai: SmartAI, card: Card): boolean? 出牌阶段要不要使用？
---@field choose_interaction? fun(skill: ActiveSkill, ai: SmartAI): boolean?
---@field choose_cards? fun(skill: ActiveSkill, ai: SmartAI): boolean?
---@field choose_targets? fun(skill: ActiveSkill, ai: SmartAI, card: Card?): any
---@field skill_invoke? boolean|fun(skill: Skill, ai: SmartAI): any
---@field ask_choice? fun(skill: ActiveSkill, ai: SmartAI, choices: string[], min?: integer, max?: integer): any

--@field ask_use_card? fun(skill: ActiveSkill, ai: SmartAI): any
--@field ask_response? fun(skill: ActiveSkill, ai: SmartAI): any

---@type table<string, SmartAISkillSpec>
fk.ai_skills = {}

local function applyAI(key, spec)
  if not fk.ai_skills[key] then
    fk.ai_skills[key] = {}
  end
  for k, v in pairs(spec) do
    fk.ai_skills[key][k] = v
  end
end

---@param key string|string[]
---@param spec SmartAISkillSpec
function SmartAI.static:setSkillAI(key, spec)
  if type(key) == "table" then
    for _, k in ipairs(key) do
      applyAI(k, spec)
    end
  else
    applyAI(key, spec)
  end
end

---@param key string|string[] 可以指定不同于spec.name的key 以便复用
---@param spec SmartAISkillSpec
---@diagnostic disable-next-line
function SmartAI:setSkillAI(key, spec)
  error("This is a static method. Please use SmartAI:registerActiveSkill(...)")
end

local function hasKey(t1, t2, key)
  if (t1 and t1[key]) or (t2 and t2[key]) then return true end
end

local function callFromTables(tab, backup, key, ...)
  local fn
  if tab and tab[key] then
    fn = tab[key]
  elseif backup and backup[key] then
    fn = backup[key]
  end
  if not fn then return end
  return fn(...)
end

function SmartAI:handleAskForUseActiveSkill()
  local name = self.handler.skill_name
  local skill = Fk.skills[name] --[[@as ActiveSkill]]
  local current_skill = self:currentSkill()

  -- 两个策略表，其中优先使用_spec里面的方法
  local spec, _spec = fk.ai_skills[name], nil
  if current_skill then
    _spec = fk.ai_skills[current_skill.name]
  end

  if hasKey(_spec, spec, "choose_interaction") then
    if not callFromTables(_spec, spec, "choose_interaction", skill, self) then
      return
    end
  end

  if hasKey(_spec, spec, "choose_cards") then
    if not callFromTables(_spec, spec, "choose_cards", skill, self) then
      return
    end
  end

  local card = self:getSelectedCard()
  if card then spec = fk.ai_skills[card.skill.name] end
  local ret = callFromTables(_spec, spec, "choose_targets", skill, self, card)
  if ret and ret ~= "" then return ret end
end

function SmartAI:handlePlayCard()
  local to_use = self:getEnabledCards()
  table.insertTable(to_use, self:getEnabledSkills())

  -- local value_func = function(str) return 1 end
  -- for _, id_or_skill in fk.sorted_pairs(to_use, value_func) do
  for _, id_or_skill in ipairs(to_use) do
    local skill
    local card

    if type(id_or_skill) == "string" then
      skill = Fk.skills[id_or_skill] --[[@as ActiveSkill]]
    else
      card = Fk:getCardById(id_or_skill)
      skill = card.skill
    end

    local spec = fk.ai_skills[skill.name]
    if spec and spec.will_use and spec.will_use(skill, self, card) then
      if not card then
        self:selectSkill(id_or_skill, true)
        if spec.choose_interaction and not spec.choose_interaction(skill, self) then
          goto continue
        end
        if spec.choose_cards and not spec.choose_cards(skill, self) then
          goto continue
        end
        card = self:getSelectedCard() -- 可能nil 但总之也要进入最终选目标阶段
        if card then spec = fk.ai_skills[card.skill.name] end
      else
        self:selectCard(id_or_skill, true)
      end

      local ret = spec.choose_targets(skill, self, card)
      if ret and ret ~= "" then return ret end
    end

    ::continue::
    self:unSelectAll()
  end

  return ""
end

---------------------------------------------------------------------

-- 其他交互：不涉及面板而是基于弹窗式的交互
-- 这块就灵活变通了，没啥非常通用的回复格式
-- ========================================

-- AskForSkillInvoke
-- 只能选择确定或者取消的交互。
-- 函数返回true或者false即可。
-----------------------------

---@type table<string, boolean | fun(self: SmartAI, prompt: string): bool>
fk.ai_skill_invoke = { AskForLuckCard = false }

function SmartAI:handleAskForSkillInvoke(data)
  local skillName, prompt = data[1], data[2]
  local skill = Fk.skills[skillName]
  local spec = fk.ai_skills[skillName]
  local ask
  if spec then
    ask = spec.skill_invoke
  else
    ask = fk.ai_skill_invoke[skillName]
  end


  if type(ask) == "function" then
    return ask(skill, self) and "1" or ""
  elseif type(ask) == "boolean" then
    return ask and "1" or ""
  elseif Fk.skills[skillName].frequency == Skill.Frequent then
    return "1"
  else
    return math.random() < 0.5 and "1" or ""
  end
end

-- 敌友判断相关。
-- 目前才开始，做个明身份打牌的就行了。
--========================================

---@param target ServerPlayer
function SmartAI:isFriend(target)
  if Self.role == target.role then return true end
  local t = { "lord", "loyalist" }
  if table.contains(t, Self.role) and table.contains(t, target.role) then return true end
  if Self.role == "renegade" or target.role == "renegade" then return math.random() < 0.6 end
  return false
end

---@param target ServerPlayer
function SmartAI:isEnemy(target)
  return not self:isFriend(target)
end

-- 排序相关函数。
-- 众所周知AI要排序，再选出尽可能最佳的选项。
-- 这里提供了常见的完整排序和效率更高的不完整排序。
--=================================================

-- sorted_pairs 见 core/util.lua

return SmartAI
