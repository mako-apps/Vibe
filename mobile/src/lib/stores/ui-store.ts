import { create } from 'zustand'

interface UIState {
    headerOpacity: number
    headerTranslateY: number
    isDrawerOpen: boolean
    isSettingsOpen: boolean
    isHistoryPanelOpen: boolean
    isModalOpen: boolean
    isHomeEditing: boolean
    setHeaderOpacity: (opacity: number) => void
    setHeaderTranslateY: (y: number) => void
    setDrawerOpen: (open: boolean) => void
    setSettingsOpen: (open: boolean) => void
    setHistoryPanelOpen: (open: boolean) => void
    setModalOpen: (open: boolean) => void
    setHomeEditing: (editing: boolean) => void
}

export const useUIStore = create<UIState>((set) => ({
    headerOpacity: 1,
    headerTranslateY: 0,
    isDrawerOpen: false,
    isSettingsOpen: false,
    isHistoryPanelOpen: false,
    isModalOpen: false,
    isHomeEditing: false,
    setHeaderOpacity: (headerOpacity) => set({ headerOpacity }),
    setHeaderTranslateY: (headerTranslateY) => set({ headerTranslateY }),
    setDrawerOpen: (isDrawerOpen) => set({ isDrawerOpen }),
    setSettingsOpen: (isSettingsOpen) => set({ isSettingsOpen }),
    setHistoryPanelOpen: (isHistoryPanelOpen) => set({ isHistoryPanelOpen }),
    setModalOpen: (isModalOpen) => set({ isModalOpen }),
    setHomeEditing: (isHomeEditing) => set({ isHomeEditing }),
}))
