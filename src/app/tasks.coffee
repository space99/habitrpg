scoring = require './scoring'
helpers = require './helpers'
_ = require 'underscore'
moment = require 'moment'
character = require './character'
derby = require 'derby'

module.exports.view = (view) ->
  view.fn 'taskClasses', (task, filters) ->
    return unless task
    {type, completed, value, repeat} = task

    for filter, enabled of filters
      if enabled and not task.tags?[filter]
        # All the other classes don't matter
        return 'hide'

    classes = type

    # show as completed if completed (naturally) or not required for today
    if type in ['todo', 'daily']
      if completed or (repeat and repeat[helpers.dayMapping[moment().day()]]==false)
        classes += " completed"
      else
        classes += " uncompleted"

    if value < -20
      classes += ' color-worst'
    else if value < -10
      classes += ' color-worse'
    else if value < -1
      classes += ' color-bad'
    else if value < 1
      classes += ' color-neutral'
    else if value < 5
      classes += ' color-good'
    else if value < 10
      classes += ' color-better'
    else
      classes += ' color-best'
    return classes

module.exports.app = (appExports, model) ->
  user = model.at('_user')

  appExports.addTask = (e, el, next) ->
    type = $(el).attr('data-task-type')
    list = model.at "_user.#{type}List"
    newModel = model.at('_new' + type.charAt(0).toUpperCase() + type.slice(1))
    text = newModel.get()
    # Don't add a blank task; 20/02/13 Added a check for undefined value, more at issue #463 -lancemanfv
    if /^(\s)*$/.test(text) || text == undefined
      console.error "Task text entered was an empty string."
      return

    newModel.set ''
    id = derby.uuid()
    switch type

      when 'habit'
        list.unshift {id: id, type: type, text: text, notes: '', value: 0, up: true, down: true}

      when 'reward'
        list.unshift {id: id, type: type, text: text, notes: '', value: 20 }

      when 'daily'
        list.unshift {id: id, type: type, text: text, notes: '', value: 0, repeat:{su:true,m:true,t:true,w:true,th:true,f:true,s:true}, completed: false }

      when 'todo'
        list.unshift {id: id, type: type, text: text, notes: '', value: 0, completed: false }

  appExports.del = (e, el) ->
    # Derby extends model.at to support creation from DOM nodes
    task = e.at()
    id = task.get('id')
    taskType = task.get('type')

    history = task.get('history')
    if history and history.length>2
      # prevent delete-and-recreate hack on red tasks
      if task.get('value') < 0
        result = confirm("Are you sure? Deleting this task will hurt you (to prevent deleting, then re-creating red tasks).")
        if result != true
          return # Cancel. Don't delete, don't hurt user
        else
          task.set('type','habit') # hack to make sure it hits HP, instead of performing "undo checkbox"
          scoring.score(model, taskType, id, direction:'down')

        # prevent accidently deleting long-standing tasks
      else
        result = confirm("Are you sure you want to delete this task?")
        return if result != true

    $('[rel=tooltip]').tooltip('hide')
    task.remove()

  appExports.clearCompleted = (e, el) ->
    # TODO: this is broken
    todos = model.get('_user.todoList')
    removed = false
    _.each model.get('_user.todoList'), (task) ->
      if task.completed
        removed = true
        todos.splice(todos.indexOf(task), 1)
    if removed
      user.set('_user.todoList', todos)

  appExports.toggleDay = (e, el) ->
    task = model.at(e.target)
    if /active/.test($(el).attr('class')) # previous state, not current
      task.set('repeat.' + $(el).attr('data-day'), false)
    else
      task.set('repeat.' + $(el).attr('data-day'), true)

  appExports.toggleTaskState = (e, el) ->
    task = model.at(e.target)
    currentState = task.get('_state')
    nextState = $(el).attr('data-task-state')
    if currentState == nextState
      nextState = 'default'
    task.set('_state', nextState)

  appExports.toggleChart = (e, el) ->
    hideSelector = $(el).attr('data-hide-id')
    chartSelector = $(el).attr('data-toggle-id')
    historyPath = $(el).attr('data-history-path')
    $(document.getElementById(hideSelector)).hide()
    $(document.getElementById(chartSelector)).toggle()

    matrix = [['Date', 'Score']]
    for obj in model.get(historyPath)
      date = +new Date(obj.date)
      readableDate = moment(date).format('MM/DD')
      matrix.push [ readableDate, obj.value ]
    data = google.visualization.arrayToDataTable matrix

    options = {
      title: 'History'
      #TODO use current background color: $(el).css('background-color), but convert to hex (see http://goo.gl/ql5pR)
      backgroundColor: 'whiteSmoke'
    }

    chart = new google.visualization.LineChart(document.getElementById( chartSelector ))
    chart.draw(data, options)

  appExports.changeContext = (e, el) ->
    # Get the data from the element
    targetSelector = $(el).attr('data-target')
    newContext = $(el).attr('data-context')
    newActiveNav = $(el).parent('li')

    # If the clicked nav is already active, do nothing
    if newActiveNav.hasClass('active')
      return

    # Find the old active nav and context
    oldActiveNav = $(el).closest('ul').find('> .active')
    oldContext = oldActiveNav.find('a').attr('data-context')

    # Set the new active nav
    oldActiveNav.removeClass('active')
    newActiveNav.addClass('active')

    # Set the new context on the target
    target = $(targetSelector)
    target.removeClass(oldContext)
    target.addClass(newContext)

  appExports.addTag = (e, el) ->
    tagId = $(el).attr('data-tag-id')
    taskId = $(el).attr('data-task-id')
    taskType = $(el).attr('data-task-type')
    tasks = model.get "_user.#{taskType}List"
    index = _.indexOf tasks, _.findWhere(tasks, {id: taskId})
    path = "_user.#{taskType}List.#{index}.tags.#{tagId}"
    model.set path, !(model.get path)

  setUndo = (stats, task) ->
    previousUndo = model.get('_undo')
    clearTimeout(previousUndo.timeoutId) if previousUndo?.timeoutId
    timeoutId = setTimeout (-> model.del('_undo')), 10000
    model.set '_undo', {stats:stats, task:task, timeoutId: timeoutId}


  ###
    Call scoring functions for habits & rewards (todos & dailies handled below)
  ###
  appExports.score = (e, el) ->
    task = model.at $(el).parents('li')[0]
    taskObj = task.get()
    direction = $(el).attr('data-direction')

    # set previous state for undo
    setUndo _.clone(user.get('stats')), _.clone(taskObj)

    scoring.score(model, taskObj.type, taskObj.id, direction)

  ###
    This is how we handle appExports.score for todos & dailies. Due to Derby's special handling of `checked={:task.completd}`,
    the above function doesn't work so we need a listener here
  ###
  user.on 'set', '(todo|daily)List.*.completed', (type, index, completed, previous, isLocal, passed) ->
    return if passed? && passed.cron # Don't do this stuff on cron
    direction = if completed then 'up' else 'down'

    # set previous state for undo
    taskObj = _.clone user.get("#{type}List.#{index}")
    taskObj.completed = previous
    setUndo _.clone(user.get('stats')), taskObj

    scoring.score(model, type, taskObj.id, direction)

  ###
    Undo
  ###
  appExports.undo = () ->
    undo = model.get '_undo'
    clearTimeout(undo.timeoutId) if undo?.timeoutId
    batch = character.BatchUpdate(model)
    batch.startTransaction()
    model.del '_undo'
    _.each undo.stats, (val, key) -> batch.set "stats.#{key}", val
    list = model.get "_user.#{undo.task.type}List"
    index = _.indexOf list, _.findWhere(list, {id: undo.task.id})
    taskPath = "#{undo.task.type}List.#{index}"
    _.each undo.task, (val, key) ->
      return if key in ['id', 'type'] # strange bugs in this world: https://workflowy.com/shared/a53582ea-43d6-bcce-c719-e134f9bf71fd/
      if key is 'completed'
        # TODO: This doesn't work since the change to no refLists, completed doesn't update
        user.pass({cron:true}).set("#{taskPath}.completed",val)
      else
        batch.set "#{taskPath}.#{key}", val
    batch.commit()

  appExports.tasksToggleAdvanced = (e, el) ->
    $(el).next('.advanced-option').toggleClass('visuallyhidden')

  appExports.tasksSaveAndClose = ->
    # When they update their notes, re-establish tooltip & popover
    $('[rel=tooltip]').tooltip()
    $('[rel=popover]').popover()

  appExports.tasksSetPriority = (e, el) ->
    dataId = $(el).parent('[data-id]').attr('data-id')
    #"_user.tasks.#{dataId}"
    model.at(e.target).set 'priority', $(el).attr('data-priority')
