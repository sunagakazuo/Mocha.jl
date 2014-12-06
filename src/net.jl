export Net
export init, destroy, forward, backward, forward_backward, get_epoch
export show_statistics, reset_statistics

type Net{T <: Backend}
  name           :: String
  backend        :: T

  # all layers, sorted in topological order
  layers         :: Vector{Layer}

  states         :: Vector{LayerState}
  blobs_forward  :: Vector{Vector{Blob}}
  blobs_backward :: Vector{Vector{Blob}}
  data_layers    :: Vector{Int}

  output_blobs   :: Dict{Symbol, Blob}
  diff_blobs     :: Dict{Symbol, Blob}
end

function get_epoch(net::Net)
  if length(net.data_layers) == 0
    error("No data layer in the net, cannot get epoch")
  end
  return net.states[net.data_layers[1]].epoch
end

function init(net::Net)
  @debug("Init network $(net.name)")
  for i = 1:length(net.layers)
    state = net.states[i]
    if has_param(net.layers[i])
      for param in state.parameters
        if !isa(param.initializer, NullInitializer)
          @debug("Init parameter $(param.name) for layer $(net.layers[i].name)")
          init(param.initializer, param.blob)
        end
      end
    end
  end
end
function destroy(net::Net)
  @debug("Destroying network $(net.name)")
  for state in net.states
    shutdown(net.backend, state)
  end
end

function dump_statistics(storage, net::Net; show=false)
  for i = 1:length(net.layers)
    if has_stats(net.layers[i])
      dump_statistics(storage, net.states[i], show)
    end
  end
end
function reset_statistics(net::Net)
  for i = 1:length(net.layers)
    if has_stats(net.layers[i])
      reset_statistics(net.states[i])
    end
  end
end

function forward_backward(net::Net, regu_coef :: FloatingPoint = 0.0)
  obj_val = forward(net, regu_coef)
  backward(net, regu_coef)
  return obj_val
end

function forward(net::Net, regu_coef :: FloatingPoint = 0.0)
  obj_val = 0.0

  for i = 1:length(net.layers)
    forward(net.backend, net.states[i], net.blobs_forward[i])

    if has_neuron(net.layers[i]) && !isa(net.layers[i].neuron, Neurons.Identity)
      for blob in net.states[i].blobs
        forward(net.backend, net.layers[i].neuron, blob)
      end
    end

    if has_loss(net.layers[i])
      obj_val += net.states[i].loss
    end

    #-- Whether or not computing regularizer forward does not affect the
    #-- back propagation results. It just makes the objective function
    #-- look more "consistent". To comment out the computation by default
    #-- just to save computational resources.
    #
    # # handle regularization
    # if has_param(net.layers[i])
    #   for param in net.states[i].parameters
    #     obj_val += forward(net.backend, param.regularizer, regu_coef, param.blob)
    #   end
    # end
  end

  return obj_val
end

function backward(net::Net, regu_coef :: FloatingPoint = 0.0)
  for i = length(net.layers):-1:1
    if has_neuron(net.layers[i]) && !isa(net.layers[i].neuron, Neurons.Identity)
      state = net.states[i]
      for j = 1:length(state.blobs)
        backward(net.backend, net.layers[i].neuron, state.blobs[j], state.blobs_diff[j])
      end
    end
    backward(net.backend, net.states[i], net.blobs_forward[i], net.blobs_backward[i])

    # handle regularization
    if has_param(net.layers[i])
      for param in net.states[i].parameters
        backward(net.backend, param.regularizer, regu_coef, param.blob, param.gradient)
      end
    end
  end
end


Net(name::String, backend::Backend, layers :: Vector{Layer}) = begin
  layers = topological_sort(layers)
  data_layers = find(l -> is_source(l), layers)

  n = length(layers)
  states = Array(LayerState, n)
  blobs_forward = Array(Vector{Blob}, n)
  blobs_backward = Array(Vector{Blob}, n)

  output_blobs = Dict{Symbol,Blob}()
  diff_blobs = Dict{Symbol,Blob}()

  for i = 1:n
    layer = layers[i]
    # record if layers has any dependency
    if :bottoms ∈ names(layer)
      blob_fwd = Blob[output_blobs[x] for x in layer.bottoms]
      blob_bwd = Blob[diff_blobs[x] for x in layer.bottoms]
    else
      blob_fwd = Blob[]
      blob_bwd = Blob[]
    end

    if has_param(layers[i])
      params = registry_get(backend, param_key(layers[i]))
    else
      params = nothing
    end
    states[i] = setup(backend, layers[i], params, blob_fwd, blob_bwd)
    if has_param(layers[i])
      registry_put(backend, param_key(layers[i]), states[i].parameters)
    end

    if !is_sink(layer) && !is_inplace(layer)
      for j = 1:length(layer.tops)
        output_blobs[layer.tops[j]] = states[i].blobs[j]
      end
      if can_do_bp(layer)
        for j = 1:length(layer.tops)
          diff_blobs[layer.tops[j]] = states[i].blobs_diff[j]
        end
      else
        for j = 1:length(layer.tops)
          diff_blobs[layer.tops[j]] = NullBlob()
        end
      end
    end

    blobs_forward[i] = blob_fwd
    blobs_backward[i] = blob_bwd
  end

  return Net(name, backend, layers, states, blobs_forward, blobs_backward, data_layers, output_blobs, diff_blobs)
end

function topological_sort(layers :: Vector{Layer})
  n = length(layers)

  #---- Build dependency graph
  graph = zeros(Int, n, n)
  outputs = Dict{Symbol, Int}()
  output_taken = Dict{Symbol, Bool}()

  for i = 1:n
    if !is_sink(layers[i]) && !is_inplace(layers[i])
      for key in layers[i].tops
        if haskey(outputs, key)
          throw(TopologyError("Duplicated output blob name: $(key)"))
        end
        outputs[key] = i
        output_taken[key] = false
      end
    end
  end

  for i = 1:n
    if !is_source(layers[i])
      for key in layers[i].bottoms
        if !haskey(outputs, key)
          throw(TopologyError("Required input blob missing: $(key)"))
        end
        if can_do_bp(layers[i]) && !is_inplace(layers[i]) && output_taken[key]
          throw(TopologyError("""Output blob $key is being used in multiple places as input blob.
          Fix this if it is a bug. Or if sharing is intended, use the SplitLayer.
          SplitLayer explicitly to allow the back-propagation operate properly."""))
        end

        graph[i,outputs[key]] = 1
        if can_do_bp(layers[i])
          output_taken[key] = true
        end
      end
    end
  end

  #---- Topological sort
  index = Int[]
  while length(index) < n
    # find layers that has no dependency
    idx = find(sum(graph,2) .== 0)
    if length(idx) == 0
      throw(TopologyError("Can't finish topological sort, cycle in layer dependency?"))
    end

    # inplace layers should always be put first
    idx_inplace = filter(i -> is_inplace(layers[i]), idx)
    idx_normal  = filter(i -> !is_inplace(layers[i]), idx)
    idx = [idx_inplace, idx_normal]

    push!(index, idx...)
    graph[idx,:] = 2 # make sure we don't select those again
    graph[:,idx] = 0 # layers that depend on those could be selected
  end

  return layers[index]
end

# make sure the network topology is good for backward propagation
function check_bp_topology(net::Net)
  bp_ready = Dict{Symbol,Bool}()
  for layer = net.layers
    if !is_sink(layer) && !is_inplace(layer)
      for blob in layer.tops
        bp_ready[blob] = false
      end
    end
  end

  # travel top down
  for i = length(net.layers):-1:1
    layer = net.layers[i]

    if can_do_bp(layer)
      if is_sink(layer)
        # ready to do bp by itself
        for blob in layer.bottoms
          bp_ready[blob] = true
        end
      else
        if !is_inplace(layer) # ignore inplace layers
          # normal layer, bp ready only if upper blobs bp ready
          for j = 1:length(layer.tops)
            if !bp_ready[layer.tops[j]] && !isa(net.states[i].blobs_diff[j], NullBlob)
              throw(TopologyError("Blob $(layer.tops[j]) in layer $(layer.name) is not connected to a loss, cannot do back-propagation"))
            end
          end
          # now we are also bp ready
          for blob in layer.bottoms
            bp_ready[blob] = true
          end
        end
      end
    end
  end
end
